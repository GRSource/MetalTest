

import Foundation
import AVFoundation



protocol ImageConsumer: AnyObject {
    func newTextureAvailable(_ texture:MTLTexture)
}

class Camera: NSObject {
    let captureSession: AVCaptureSession
    
    let cameraProcessingQueue = DispatchQueue.global()//开启子线程采集原始数据
    
    
    var videoTextureCache: CVMetalTextureCache?
    
    var yuvLookupTable: [String:(Int, MTLDataType)] = [:]//metal文件参数表
    
    let frameRenderingSemaphore = DispatchSemaphore(value:1)//单次只渲染一帧
    
    
    var yuvConversionRenderPipelineState:MTLRenderPipelineState!//渲染管线
    var imageConsumer: ImageConsumer?
    
    override init() {
        
        //创建会话
        captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        //创建输入设备
        let device = AVCaptureDevice.default(for: .video)
        let videoInput = try! AVCaptureDeviceInput(device: device!)
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }
        
        //创建输出
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        captureSession.sessionPreset = .vga640x480
        captureSession.commitConfiguration()
        
        super.init()
        videoOutput.setSampleBufferDelegate(self, queue: cameraProcessingQueue)
        
        
        let _ = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, sharedMetalRenderingDevice.device, nil, &videoTextureCache)
        
        let (pipelineState, _) = generateRenderPipelineState(device: sharedMetalRenderingDevice, vertexFunctionName: "twoInputVertex", fragmentFunctionName: "yuvConversionFullRangeFragment", operationName: "YUVToRGB")
        self.yuvConversionRenderPipelineState = pipelineState
    }
    
    func addConsumer(_ consumer: ImageConsumer) {
        self.imageConsumer = consumer
    }
    
    func startCapture() {
        if (!captureSession.isRunning) {
            print("开始采集")
            captureSession.startRunning()
        }
    }
    
    
    
    func convertYUVToRGB(pipelineState: MTLRenderPipelineState, luminanceTexture: MTLTexture, chrominanceTexture: MTLTexture, colorConversionMatrix: [Float], resultTexture: MTLTexture) {

//        let colorConversionMatrix: [Float] = [
//            1.0,    1.0,    1.0,    0.0,
//            0.0,    -0.343, 1.765,  0.0,
//            1.4,    -0.711, 0.0,    0.0
//        ]
        let textureCoordinates: [Float] = [
            0.0,  1.0,
            0.0,  0.0,
            1.0,  1.0,
            1.0,  0.0,
        ]

        
        let commandBuffer = sharedMetalRenderingDevice.metalQueue.makeCommandBuffer()!
        
        commandBuffer.renderQuad(pipelineState: pipelineState, uniform: colorConversionMatrix, inputTextures: [0: luminanceTexture, 1: chrominanceTexture], textureCoordinates: textureCoordinates, outputTexture: resultTexture)
        
        commandBuffer.commit()
    
    }
}


extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard (frameRenderingSemaphore.wait(timeout:DispatchTime.now()) == DispatchTimeoutResult.success) else { return }
        let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let bufferWidth = CVPixelBufferGetWidth(cameraFrame)
        let bufferHeight = CVPixelBufferGetHeight(cameraFrame)
        var yuvConversionRgbMatrix: [Float] = []
        if let colorAttachment = CVBufferGetAttachment(cameraFrame, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue(), CFGetTypeID(colorAttachment) == CFStringGetTypeID() {
            let colorAttachmentString = colorAttachment as! CFString
            if colorAttachmentString == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
//                let matrix601Default: [Float] = [
//                    1.164,  1.164,   1.164, 0,
//                    0.0,   -0.392,   2.017, 0,
//                    1.596, -0.813,   0.0,   0
//                ]
                let matrix601FullRange: [Float] = [
                    1.0,    1.0,    1.0,   0,
                    0.0,    -0.343, 1.765, 0,
                    1.4,    -0.711, 0.0,   0
                ]
                yuvConversionRgbMatrix = matrix601FullRange
            } else if colorAttachmentString == kCVImageBufferYCbCrMatrix_ITU_R_709_2 {
                let matrix709Default: [Float] = [
                    1.164,  1.164, 1.164, 0,
                    0.0, -0.213, 2.112,   0,
                    1.793, -0.533,   0.0, 0
                ]
                yuvConversionRgbMatrix = matrix709Default
            }
            
        }
        
        CVPixelBufferLockBaseAddress(cameraFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))//访问帧数据时先上锁
        
        var luminanceTextureRef: CVMetalTexture!
        var chrominanceTextureRef: CVMetalTexture!
        // Luminance plane
        let _ = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .r8Unorm, bufferWidth, bufferHeight, 0, &luminanceTextureRef)
        // Chrominance plane
        let _ = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .rg8Unorm, bufferWidth / 2, bufferHeight / 2, 1, &chrominanceTextureRef)
        let luminanceTexture = CVMetalTextureGetTexture(luminanceTextureRef)
        let chrominanceTexture = CVMetalTextureGetTexture(chrominanceTextureRef)
        
        //宽高调换顺序
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: bufferHeight, height: bufferWidth, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        let newTexture = sharedMetalRenderingDevice.device.makeTexture(descriptor: textureDescriptor)!

//        convertYUVToRGB(pipelineState: yuvConversionRenderPipelineState, luminanceTexture: luminanceTexture!, chrominanceTexture: chrominanceTexture!, resultTexture: newTexture)
        convertYUVToRGB(pipelineState: yuvConversionRenderPipelineState, luminanceTexture: luminanceTexture!, chrominanceTexture: chrominanceTexture!, colorConversionMatrix: yuvConversionRgbMatrix, resultTexture: newTexture)
        
        imageConsumer?.newTextureAvailable(newTexture)
        
        
        CVPixelBufferUnlockBaseAddress(cameraFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        
        frameRenderingSemaphore.signal()
    }
}

