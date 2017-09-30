//
//  ViewController.swift
//  TwoWayStopwatch iOS
//
//  Created by Alex Decker on 2017-09-29.
//  Copyright © 2017 me. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
    
    @IBOutlet weak var valueLabel: UILabel! {
        didSet {
            valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 87, weight: .regular)
        }
    }
    
    @IBOutlet weak var forwardButton: UIButton!
    @IBOutlet weak var backwardButton: UIButton!
    
    @IBOutlet weak var discardButton: UIButton! {
        didSet {
            discardButton.isHidden = true
            discardButton.titleLabel?.adjustsFontSizeToFitWidth = true
            discardButton.titleLabel?.minimumScaleFactor = 0.5
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateDisplay), name: .baseTimeUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(startDisplayTimer), name: .startUpdatingDisplay, object: nil)
        
        self.updateDisplay()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = forwardButton.bounds.size.width
        forwardButton.layer.cornerRadius = width/2
        backwardButton.layer.cornerRadius = width/2
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    var timingController: TimingController { return TimingController.controller }
    
    var displayTimer: Timer?
    
    @objc func startDisplayTimer() {
        self.displayTimer?.invalidate() // in case it's already running
        self.displayTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
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
        self.updateButtons()
    }
    
    var discardDisplayMinutes = 0
    
    @objc func updateDisplay() {
        //FIXME: This should all happen in TimingController. All I need is to get the string.
        self.valueLabel.text = timingController.displayTime
        
        let currentSessionMinutes = Int(timingController.currentSessionSeconds / 60)
        if currentSessionMinutes >= 30 {
            if currentSessionMinutes != self.discardDisplayMinutes {
                self.discardButton.isHidden = false
                self.discardButton.setTitle("Discard session (\(currentSessionMinutes) minutes)", for: .normal)
                self.discardDisplayMinutes = currentSessionMinutes
            }
        } else if self.discardDisplayMinutes != 0 {
            self.discardDisplayMinutes = 0
            self.discardButton.isHidden = true
        }
    }
    
    func updateButtons() {
        self.forwardButton.setTitle("forward", for: .normal)
        self.backwardButton.setTitle("backward", for: .normal)
        if timingController.isRunning {
            let button = (timingController.direction > 0 ? forwardButton : backwardButton)
            button?.setTitle("pause", for: .normal)
        }
    }

    @IBAction func discardSession(_ sender: UIButton) {
        self.timingController.discardSession()
        self.displayTimer?.invalidate()
        self.updateDisplay()
    }
    
}

