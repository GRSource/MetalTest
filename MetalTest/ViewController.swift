

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    let videoCamera = Camera()//成员变量防止相机被释放
    let saturationAdjustment = SaturationAdjustment()
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let rootView = self.view as! RenderView
        
        videoCamera.addConsumer(saturationAdjustment)
        saturationAdjustment.addConsumer(rootView)
        
        videoCamera.startCapture()
    }


    @IBAction func updateSliderValue(_ sender: UISlider) {
        saturationAdjustment.saturation = sender.value
    }
}
