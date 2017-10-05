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

        self.updateDisplay()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateDisplay), name: .baseTimeUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(startDisplayTimer), name: .startUpdatingDisplay, object: nil)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    var timingController: TimingController { return TimingController.controller }
    
    var displayTimer: Timer?
    
    @objc func startDisplayTimer() {
        self.displayTimer?.invalidate() // in case it's already running
        self.displayTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
    }
    
    @IBAction func startForward(_ sender: Any) {
        timingController.startForward()
        self.startDisplayTimer()
    }
    @IBAction func startBackward(_ sender: Any) {
        timingController.startBackward()
        self.startDisplayTimer()
    }
    
    @IBAction func pause(_ sender: Any? = nil) {
        timingController.pause()
        self.displayTimer?.invalidate()
        self.updateDisplay()
    }
    
    var runningSessionIsRemote = false
    
    @objc func updateDisplay() {
        if timingController.isRunningRemotely {
            self.valueLabel.stringValue = timingController.remoteDisplayTime
        } else {
            self.valueLabel.stringValue = timingController.localDisplayTime
        }
        if timingController.isRunningRemotely != self.runningSessionIsRemote {
            self.runningSessionIsRemote = timingController.isRunningRemotely
            self.valueLabel.textColor = (runningSessionIsRemote ? .blue : .black)
        }
    }
    
}

