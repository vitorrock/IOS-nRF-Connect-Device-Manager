//
//  McuMgrBleTransport+CBCentralManagerDelegate.swift
//  McuManager
//
//  Created by Dinesh Harjani on 4/5/22.
//

import Foundation
import CoreBluetooth

// MARK: - McuMgrBleTransport+CBCentralManagerDelegate

extension McuMgrBleTransport: CBCentralManagerDelegate {
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let peripheral = centralManager
                .retrievePeripherals(withIdentifiers: [identifier])
                .first {
                log(msg: "\(#function): Setting Peripheral for \(mode) mode.", atLevel: .debug)
                modePeripherals[mode] = peripheral
                connectionLock.open(key: McuMgrBleTransportKey.awaitingCentralManager.rawValue)
            } else {
                connectionLock.open(McuMgrBleTransportError.centralManagerNotReady)
            }
        default:
            connectionLock.open(McuMgrBleTransportError.centralManagerNotReady)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.identifier == peripheral.identifier else { return }

        log(msg: "Peripheral connected", atLevel: .info)
        debugConnectionTimestamp = Date()
        log(msg: "[DEBUG-DFU] didConnect - peripheral: \(peripheral.identifier), name: \(peripheral.name ?? "nil"), state: \(peripheral.state.rawValue)", atLevel: .info)
        log(msg: "[DEBUG-DFU] didConnect - smpCharacteristic before reset: \(smpCharacteristic?.uuid.uuidString ?? "nil")", atLevel: .info)
        log(msg: "[DEBUG-DFU] didConnect - timestamp: \(debugConnectionTimestamp!)", atLevel: .info)
        state = .initializing
        previousUpdateNotificationSequenceNumber = nil
        log(msg: "[DEBUG-DFU] Starting service discovery for UUID: \(configuration.serviceUUID.uuidString)", atLevel: .info)
        peripheral.delegate = self
        peripheral.discoverServices([configuration.serviceUUID])
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.identifier == peripheral.identifier else {
            return
        }
        if let error {
            let nsError = error as NSError
            log(msg: "[DEBUG-DFU] Peripheral disconnected with error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))", atLevel: .warning)
        } else {
            log(msg: "[DEBUG-DFU] Peripheral disconnected (no error)", atLevel: .info)
        }
        log(msg: "Peripheral disconnected", atLevel: .info)
        didDisconnect()
        notifyStateChanged(.disconnected)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.identifier == peripheral.identifier else {
            return
        }
        log(msg: "Peripheral failed to connect", atLevel: .warning)
        connectionLock.open(McuMgrTransportError.connectionFailed)
    }
}
