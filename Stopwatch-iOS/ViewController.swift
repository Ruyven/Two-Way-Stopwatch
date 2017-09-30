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
            //valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: NSFont.Weight.regular)
        }
    }
    
    @IBOutlet weak var forwardButton: UIButton!
    @IBOutlet weak var backwardButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.updateDisplay()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateDisplay), name: .baseTimeUpdated, object: nil)
    }
    
    var timingController: TimingController { return TimingController.controller }
    
    var displayTimer: Timer?
    
    @IBAction func startForward(_ sender: Any) {
        if timingController.isRunning, timingController.direction > 0 {
            self.pause()
            self.forwardButton.setTitle("forward", for: .normal)
            return
        }
        self.forwardButton.setTitle("pause", for: .normal)
        
        timingController.startForward()
        self.displayTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
    }
    @IBAction func startBackward(_ sender: Any) {
        if timingController.isRunning, timingController.direction > 0 {
            self.pause()
            self.backwardButton.setTitle("backward", for: .normal)
            return
        }
        self.forwardButton.setTitle("pause", for: .normal)
        
        timingController.startBackward()
        self.displayTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
    }
    
    @IBAction func pause(_ sender: Any? = nil) {
        timingController.pause()
        self.displayTimer?.invalidate()
    }
    
    @objc func updateDisplay() {
        //FIXME: This should all happen in TimingController. All I need is to get the string.
        self.valueLabel.text = timingController.displayTime
    }

}

