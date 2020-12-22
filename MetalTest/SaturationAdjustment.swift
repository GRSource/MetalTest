

import Foundation
import AVFoundation

class SaturationAdjustment: ImageConsumer {
    
    var saturation: Float = 1.0
    
    let renderPipelineState: MTLRenderPipelineState
    var imageConsumer: ImageConsumer?
    let textureInputSemaphore = DispatchSemaphore(value:1)
    
    init() {
        
        let (piplineState, _) = generateRenderPipelineState(device: sharedMetalRenderingDevice, vertexFunctionName: "oneInputVertex", fragmentFunctionName: "saturationFragment", operationName: #file)
        self.renderPipelineState = piplineState
    }
    
    func addConsumer(_ consumer: ImageConsumer) {
        self.imageConsumer = consumer
    }
    
    
    func newTextureAvailable(_ texture: MTLTexture) {
        let _ = textureInputSemaphore.wait(timeout: .distantFuture)
        defer {
            textureInputSemaphore.signal()
        }
        let outputWidth = texture.width
        let outputHeight = texture.height
        let commandBuffer = sharedMetalRenderingDevice.metalQueue.makeCommandBuffer()!
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        let newTexture = sharedMetalRenderingDevice.device.makeTexture(descriptor: textureDescriptor)!
        let textureCoordinates: [Float] = [
            0.0, 0.0,
            1.0, 0.0,
            0.0, 1.0,
            1.0, 1.0
        ]
        commandBuffer.renderQuad(pipelineState: renderPipelineState, uniform: [saturation], inputTextures: [0: texture], textureCoordinates: textureCoordinates, outputTexture: newTexture)
        commandBuffer.commit()
        textureInputSemaphore.signal()
        imageConsumer?.newTextureAvailable(newTexture)
        let _ = textureInputSemaphore.wait(timeout: .distantFuture)
    }
}
