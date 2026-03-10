//
//  McuMgrBleTransport+CBPeripheralDelegate.swift
//  McuManager
//
//  Created by Dinesh Harjani on 4/5/22.
//

import Foundation
import CoreBluetooth
import OSLog

// MARK: - McuMgrBleTransport+CBPeripheralDelegate

extension McuMgrBleTransport: CBPeripheralDelegate {
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Check for error.
        guard error == nil else {
            log(msg: "[DEBUG-DFU] didDiscoverServices ERROR: \(error!.localizedDescription) (domain: \((error! as NSError).domain), code: \((error! as NSError).code))", atLevel: .error)
            connectionLock.open(error)
            return
        }

        let s = peripheral.services?
            .map({ "\($0.uuid.uuidString) (isPrimary: \($0.isPrimary))" })
            .joined(separator: ", ")
            ?? "none"
        log(msg: "Services discovered: \(s)", atLevel: .verbose)
        log(msg: "[DEBUG-DFU] Peripheral state: \(peripheral.state.rawValue), identifier: \(peripheral.identifier)", atLevel: .info)
        log(msg: "[DEBUG-DFU] Looking for SMP service UUID: \(configuration.serviceUUID.uuidString)", atLevel: .info)

        // Get peripheral's services.
        guard let services = peripheral.services else {
            log(msg: "[DEBUG-DFU] No services found on peripheral!", atLevel: .error)
            connectionLock.open(McuMgrBleTransportError.missingService)
            return
        }
        // Find the service matching the SMP service UUID.
        for service in services {
            if service.uuid == configuration.serviceUUID {
                log(msg: "[DEBUG-DFU] Found SMP service. Discovering characteristics...", atLevel: .info)
                peripheral.discoverCharacteristics([configuration.characteristicUUUID],
                                                   for: service)
                return
            }
        }
        log(msg: "[DEBUG-DFU] SMP service NOT found among \(services.count) services!", atLevel: .error)
        connectionLock.open(McuMgrBleTransportError.missingService)
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        // Check for error.
        guard error == nil else {
            connectionLock.open(error)
            return
        }
        
        let c = service.characteristics?
            .map({ char -> String in
                let props = Self.describeProperties(char.properties)
                return "\(char.uuid.uuidString) [props: \(props)]"
            })
            .joined(separator: ", ")
            ?? "none"
        log(msg: "Characteristics discovered: \(c)", atLevel: .verbose)
        log(msg: "[DEBUG-DFU] Looking for SMP characteristic UUID: \(configuration.characteristicUUUID.uuidString)", atLevel: .info)

        // Get service's characteristics.
        guard let characteristics = service.characteristics else {
            log(msg: "[DEBUG-DFU] No characteristics found in service!", atLevel: .error)
            connectionLock.open(McuMgrBleTransportError.missingCharacteristic)
            return
        }
        // Find the characteristic matching the SMP characteristic UUID.
        for characteristic in characteristics {
            if characteristic.uuid == configuration.characteristicUUUID {
                let props = Self.describeProperties(characteristic.properties)
                log(msg: "[DEBUG-DFU] Found SMP characteristic with properties: \(props)", atLevel: .info)
                log(msg: "[DEBUG-DFU] Has .write: \(characteristic.properties.contains(.write)), .writeWithoutResponse: \(characteristic.properties.contains(.writeWithoutResponse)), .notify: \(characteristic.properties.contains(.notify))", atLevel: .info)
                // Set the characteristic notification if available.
                if characteristic.properties.contains(.notify) {
                    log(msg: "Enabling notifications...", atLevel: .verbose)
                    peripheral.setNotifyValue(true, for: characteristic)
                } else {
                    log(msg: "[DEBUG-DFU] SMP characteristic missing .notify property!", atLevel: .error)
                    connectionLock.open(McuMgrBleTransportError.missingNotifyProperty)
                }
                return
            }
        }
        log(msg: "[DEBUG-DFU] SMP characteristic NOT found!", atLevel: .error)
        connectionLock.open(McuMgrBleTransportError.missingCharacteristic)
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == configuration.characteristicUUUID else {
            return
        }
        // Check for error.
        guard error == nil else {
            connectionLock.open(error)
            return
        }
        
        log(msg: "Notifications enabled", atLevel: .verbose)
        log(msg: "[DEBUG-DFU] SMP characteristic ready. Properties: write=\(characteristic.properties.contains(.write)), writeWithoutResponse=\(characteristic.properties.contains(.writeWithoutResponse)), notify=\(characteristic.properties.contains(.notify))", atLevel: .info)

        // Set the SMP characteristic.
        smpCharacteristic = characteristic
        state = .connected
        softReset()
        notifyStateChanged(.connected)

        // The SMP Service and characteristic have now been discovered and set
        // up. Signal the dispatch semaphore to continue to send the request.
        connectionLock.open(key: McuMgrBleTransportKey.discoveringSmpCharacteristic.rawValue)
    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == configuration.characteristicUUUID else {
            return
        }

        if let error = error {
            let nsError = error as NSError
            let timeSinceConnect = debugConnectionTimestamp.map { String(format: "%.3fs", Date().timeIntervalSince($0)) } ?? "unknown"
            log(msg: "[DEBUG-DFU] didUpdateValueFor ERROR: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code)), timeSinceConnect=\(timeSinceConnect)", atLevel: .error)
            writeState.onError(error)
            return
        }
        
        // Assumption: CoreBluetooth is delivering all packets from the same sender,
        // in order.
        guard let data = characteristic.value else {
            writeState.onError(McuMgrTransportError.badResponse)
            return
        }
        
        // Check that we've received all the data for the Sequence Number of the
        // previous received Data.
        if let previousUpdateNotificationSequenceNumber = previousUpdateNotificationSequenceNumber,
           !writeState.isChunkComplete(for: previousUpdateNotificationSequenceNumber) {
            
            // Add Data to the previous Sequence Number.
            writeState.received(sequenceNumber: previousUpdateNotificationSequenceNumber, data: data)
            return
        }
        
        // If the Data is the first 'chunk', it will include the header.
        guard let sequenceNumber = data.readMcuMgrHeaderSequenceNumber() else {
            writeState.onError(McuMgrTransportError.badResponse)
            return
        }
        
        previousUpdateNotificationSequenceNumber = sequenceNumber
        writeState.received(sequenceNumber: sequenceNumber, data: data)
    }
    
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Restart any paused writes due to Peripheral not being ready for more writes.
        robWriteBuffer.peripheralReadyToWrite(peripheral)
    }

    // MARK: - Debug Helpers

    private static func describeProperties(_ props: CBCharacteristicProperties) -> String {
        var result = [String]()
        if props.contains(.broadcast) { result.append("broadcast") }
        if props.contains(.read) { result.append("read") }
        if props.contains(.writeWithoutResponse) { result.append("writeWithoutResponse") }
        if props.contains(.write) { result.append("write") }
        if props.contains(.notify) { result.append("notify") }
        if props.contains(.indicate) { result.append("indicate") }
        if props.contains(.authenticatedSignedWrites) { result.append("authenticatedSignedWrites") }
        if props.contains(.extendedProperties) { result.append("extendedProperties") }
        return result.isEmpty ? "none" : result.joined(separator: ", ")
    }
}
