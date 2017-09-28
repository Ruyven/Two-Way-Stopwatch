//
//  ViewController.swift
//  Stopwatch
//
//  Created by Alex Decker on 2017-09-24.
//  Copyright © 2017 me. All rights reserved.
//

import Cocoa

class ViewController: NSViewController {

    @IBOutlet weak var valueLabel: NSTextField! {
        didSet {
            valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: NSFont.Weight.regular)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        DataManager.manager.getTotalTime { value in
            guard let value = value else {
                return
            }
            
            self.value = value
            self.updateDisplay()
        }
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    var value: Double = 0 // hours
    var displayTimer: Timer?
    var startTime: Date = Date()
    var direction: Double = 0
    
    var isRunning: Bool {
        return self.direction != 0
    }

    @IBAction func startForward(_ sender: Any) {
        if self.isRunning {
            self.pause()
        }
        self.startTime = Date()
        self.direction = 1
        self.displayTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
    }
    @IBAction func startBackward(_ sender: Any) {
        if self.isRunning {
            self.pause()
        }
        self.startTime = Date()
        self.direction = -1
        self.displayTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
    }
    
    // seconds
    var currentTime: Double {
        return Date().timeIntervalSince(self.startTime) * self.direction
    }
    
    var valuePlusCurrent: Double {
        return self.value + self.currentTime / 3600     // hours
    }
    
    @IBAction func pause(_ sender: Any? = nil) {
        guard self.isRunning else {
            return
        }
        
        DataManager.manager.logSession(startTime: self.startTime, hours: self.currentTime/3600)
        
        self.value = self.valuePlusCurrent

        self.displayTimer?.invalidate()
        self.direction = 0
    }
    
    @objc func updateDisplay() {
        var time = self.valuePlusCurrent
        
        let vorzeichen: String
        if time >= 0 {
            vorzeichen = ""
        } else {
            vorzeichen = "-"
            time = 0 - time
        }
        
        let hours = Int(time)
        time = time - Double(hours)
        time *= 60
        let minutes = Int(time)
        time = time - Double(minutes)
        time *= 60
        let seconds = Int(time)
        time -= Double(seconds)
        let tenths = Int(time*10)
        
        self.valueLabel.stringValue = String(format: "\(vorzeichen)%d:%02d:%02d.%d", hours, minutes, seconds, tenths)
    }
    
}

