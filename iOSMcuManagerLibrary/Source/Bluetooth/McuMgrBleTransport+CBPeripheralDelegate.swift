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
        if let error = error as NSError? {
            log(msg: "[DEBUG-DFU] didDiscoverServices ERROR: domain=\(error.domain), code=\(error.code), desc=\(error.localizedDescription)", atLevel: .error)
            connectionLock.open(error)
            return
        }

        let s = peripheral.services?
            .map({ $0.uuid.uuidString })
            .joined(separator: ", ")
            ?? "none"
        log(msg: "[DEBUG-DFU] didDiscoverServices: \(s), count=\(peripheral.services?.count ?? 0)", atLevel: .info)
        log(msg: "Services discovered: \(s)", atLevel: .verbose)

        // Get peripheral's services.
        guard let services = peripheral.services else {
            connectionLock.open(McuMgrBleTransportError.missingService)
            return
        }
        // Find the service matching the SMP service UUID.
        for service in services {
            if service.uuid == configuration.serviceUUID {
                log(msg: "[DEBUG-DFU] Found SMP service: \(service.uuid.uuidString)", atLevel: .info)
                log(msg: "Discovering characteristics...", atLevel: .verbose)
                peripheral.discoverCharacteristics([configuration.characteristicUUUID],
                                                   for: service)
                return
            }
        }
        log(msg: "[DEBUG-DFU] SMP service NOT found! Looking for: \(configuration.serviceUUID.uuidString)", atLevel: .error)
        connectionLock.open(McuMgrBleTransportError.missingService)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        // Check for error.
        if let error = error as NSError? {
            log(msg: "[DEBUG-DFU] didDiscoverCharacteristics ERROR: domain=\(error.domain), code=\(error.code), desc=\(error.localizedDescription)", atLevel: .error)
            connectionLock.open(error)
            return
        }

        let c = service.characteristics?
            .map({ $0.uuid.uuidString })
            .joined(separator: ", ")
            ?? "none"
        log(msg: "[DEBUG-DFU] didDiscoverCharacteristics for service \(service.uuid.uuidString): \(c)", atLevel: .info)
        log(msg: "Characteristics discovered: \(c)", atLevel: .verbose)

        // Get service's characteristics.
        guard let characteristics = service.characteristics else {
            connectionLock.open(McuMgrBleTransportError.missingCharacteristic)
            return
        }
        // Find the characteristic matching the SMP characteristic UUID.
        for characteristic in characteristics {
            if characteristic.uuid == configuration.characteristicUUUID {
                let props = describeProperties(characteristic.properties)
                log(msg: "[DEBUG-DFU] Found SMP characteristic: \(characteristic.uuid.uuidString), properties: \(props)", atLevel: .info)
                // Set the characteristic notification if available.
                if characteristic.properties.contains(.notify) {
                    log(msg: "Enabling notifications...", atLevel: .verbose)
                    peripheral.setNotifyValue(true, for: characteristic)
                } else {
                    log(msg: "[DEBUG-DFU] SMP characteristic MISSING notify property! properties: \(props)", atLevel: .error)
                    connectionLock.open(McuMgrBleTransportError.missingNotifyProperty)
                }
                return
            }
        }
        log(msg: "[DEBUG-DFU] SMP characteristic NOT found! Looking for: \(configuration.characteristicUUUID.uuidString)", atLevel: .error)
        connectionLock.open(McuMgrBleTransportError.missingCharacteristic)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == configuration.characteristicUUUID else {
            return
        }
        // Check for error.
        if let error = error as NSError? {
            log(msg: "[DEBUG-DFU] didUpdateNotificationState ERROR: domain=\(error.domain), code=\(error.code), desc=\(error.localizedDescription)", atLevel: .error)
            connectionLock.open(error)
            return
        }

        let props = describeProperties(characteristic.properties)
        log(msg: "[DEBUG-DFU] Notifications enabled for: \(characteristic.uuid.uuidString), properties: \(props)", atLevel: .info)
        log(msg: "Notifications enabled", atLevel: .verbose)

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
            let timeSinceConnect = debugConnectionTimestamp.map { "\(Date().timeIntervalSince($0))s" } ?? "unknown"
            log(msg: "[DEBUG-DFU] didUpdateValueFor ERROR: domain=\(nsError.domain), code=\(nsError.code), desc=\(nsError.localizedDescription), timeSinceConnect=\(timeSinceConnect)", atLevel: .error)
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
}

// MARK: - Debug Helpers

private extension McuMgrBleTransport {

    func describeProperties(_ props: CBCharacteristicProperties) -> String {
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
