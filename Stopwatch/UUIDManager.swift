//
//  UUIDManager.swift
//  TwoWayStopwatch
//
//  Created by Alex Decker on 2017-09-30.
//  Copyright © 2017 me. All rights reserved.
//

#if os(OSX)
    import IOKit
#elseif os(iOS)
    import UIKit
#endif

class UUIDManager {
    static func generateUUID() -> String {
        #if os(OSX)
            // get this device's serial number
            // Get the platform expert
            let platformExpert: io_service_t = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
            
            // Get the serial number as a CFString ( actually as Unmanaged<AnyObject>! )
            let serialNumberAsCFString = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0);
            
            // Release the platform expert (we're responsible)
            IOObjectRelease(platformExpert);
            
            // Take the unretained value of the unmanaged-any-object
            // (so we're not responsible for releasing it)
            // and pass it back as a String or, if it fails, an empty string
            return serialNumberAsCFString!.takeUnretainedValue() as! String
        #elseif os(iOS)
            // from the documentation:
            // If the value is nil, wait and get the value again later. This happens, for example, after the device has been restarted but before the user has unlocked the device.
            return UIDevice.current.identifierForVendor!.uuidString
        #endif
    }
}
