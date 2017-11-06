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
    
    @IBOutlet weak var backwardButton: NSButton!
    @IBOutlet weak var forwardButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        self.updateTimerDisplay()
        
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
        self.displayTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateTimerDisplay), userInfo: nil, repeats: true)
        self.updateButtons()
    }
    
    @IBAction func startForward(_ sender: Any) {
        if timingController.isRunning, timingController.direction > 0 {
            self.pause()
            return
        }
        
        timingController.startForward()
        self.startDisplayTimer()
    }
    @IBAction func startBackward(_ sender: Any) {
        if timingController.isRunning, timingController.direction < 0 {
            self.pause()
            return
        }
        
        timingController.startBackward()
        self.startDisplayTimer()
    }
    
    @IBAction func pause(_ sender: Any? = nil) {
        timingController.pause()
        self.displayTimer?.invalidate()
        self.updateDisplay()
    }
    
    @objc func updateDisplay() {
        self.updateTimerDisplay()
        self.updateButtons()
    }
    
    var runningSessionIsRemote = false
    
    @objc func updateTimerDisplay() {
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
    
    func updateButtons() {
        self.forwardButton.title = "Forward"
        self.backwardButton.title = "Backward"
        let direction = timingController.direction
        
        if timingController.isRunning {
            let button = (direction > 0 ? forwardButton : backwardButton)
            button?.title = "Pause"
        }
        
        /*let activeColor = UIColor.white
        let activeBorderWidth: CGFloat = 2
        if direction > 0 {
            self.forwardButton.setBorder(color: activeColor, width: activeBorderWidth)
        } else {
            self.forwardButton.setBorder(color: nil, width: 0)
        }
        if direction < 0 {
            self.backwardButton.setBorder(color: activeColor, width: activeBorderWidth)
        } else {
            self.backwardButton.setBorder(color: nil, width: 0)
        }*/
    }
    
}

