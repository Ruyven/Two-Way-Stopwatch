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
        
        self.updateTimerDisplay()
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
    
    var discardDisplayMinutes = 0
    
    @objc func updateDisplay() {
        self.updateTimerDisplay()
        self.updateButtons()
    }
    
    var runningSessionIsRemote = false
    
    @objc func updateTimerDisplay() {
        if timingController.isRunningRemotely {
            self.valueLabel.text = timingController.remoteDisplayTime
        } else {
            self.valueLabel.text = timingController.localDisplayTime
        }
        if timingController.isRunningRemotely != self.runningSessionIsRemote {
            self.runningSessionIsRemote = timingController.isRunningRemotely
            self.valueLabel.textColor = (runningSessionIsRemote ? .cyan : .white)
        }
        
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
        let direction = timingController.direction

        if timingController.isRunning {
            let button = (direction > 0 ? forwardButton : backwardButton)
            button?.setTitle("pause", for: .normal)
        }
        
        let activeColor = UIColor.white
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
        }
    }

    @IBAction func discardSession(_ sender: UIButton) {
        self.timingController.discardSession()
        self.displayTimer?.invalidate()
        self.updateDisplay()
    }
    
}

extension UIView {
    func setBorder(color: UIColor?, width: CGFloat) {
        self.layer.borderColor = color?.cgColor
        self.layer.borderWidth = width
    }
}
