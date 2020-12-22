
import UIKit
import AVFoundation
import MetalKit

let sharedMetalRenderingDevice = MetalRenderingDevice()


class RenderView: MTKView, ImageConsumer {

    var currentTexture: MTLTexture?
    var renderPipelineState:MTLRenderPipelineState!
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        
        framebufferOnly = false
        autoResizeDrawable = true
        self.device = sharedMetalRenderingDevice.device
        let (pipelineState, _) = generateRenderPipelineState(device: sharedMetalRenderingDevice, vertexFunctionName: "oneInputVertex", fragmentFunctionName: "passthroughFragment", operationName: "RenderView")
        self.renderPipelineState = pipelineState
        enableSetNeedsDisplay = false
        isPaused = true
        
    }
    func newTextureAvailable(_ texture: MTLTexture) {
        self.drawableSize = CGSize(width: texture.width, height: texture.height)
        currentTexture = texture
        self.draw()
    }
    
    override func draw(_ rect: CGRect) {
        if let currentDrawable = self.currentDrawable, let imageTexture = currentTexture {
            let commandBuffer = sharedMetalRenderingDevice.metalQueue.makeCommandBuffer()
            let outputTexture = currentDrawable.texture
            let textureCoordinates: [Float] = [
                0.0,  0.0,
                1.0,  0.0,
                0.0,  1.0,
                1.0,  1.0,
            ]

            commandBuffer?.renderQuad(pipelineState: renderPipelineState, inputTextures: [0: imageTexture], textureCoordinates: textureCoordinates, outputTexture: outputTexture)
            
            commandBuffer?.present(currentDrawable)
            commandBuffer?.commit()
        }
    }

}

class MetalRenderingDevice {
    
    var device: MTLDevice!
    var metalQueue: MTLCommandQueue!
    var metalLibrary: MTLLibrary!
    
    init() {
        device = MTLCreateSystemDefaultDevice()
        metalQueue = device!.makeCommandQueue()!
        metalLibrary = device!.makeDefaultLibrary()!
    }
    
    
}


func generateRenderPipelineState(device:MetalRenderingDevice, vertexFunctionName:String, fragmentFunctionName:String, operationName:String) -> (MTLRenderPipelineState, [String:(Int, MTLDataType)]) {
    guard let vertexFunction = device.metalLibrary.makeFunction(name: vertexFunctionName) else {
        fatalError("\(operationName): could not compile vertex function \(vertexFunctionName)")
    }
    
    guard let fragmentFunction = device.metalLibrary.makeFunction(name: fragmentFunctionName) else {
        fatalError("\(operationName): could not compile fragment function \(fragmentFunctionName)")
    }
    
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormat.bgra8Unorm
    descriptor.rasterSampleCount = 1
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    
    do {
        var reflection:MTLAutoreleasedRenderPipelineReflection?
        let pipelineState = try device.device.makeRenderPipelineState(descriptor: descriptor, options: [.bufferTypeInfo, .argumentInfo], reflection: &reflection)

        var uniformLookupTable:[String:(Int, MTLDataType)] = [:]
        if let fragmentArguments = reflection?.fragmentArguments {
            for fragmentArgument in fragmentArguments where fragmentArgument.type == .buffer {
                if
                  (fragmentArgument.bufferDataType == .struct),
                  let members = fragmentArgument.bufferStructType?.members.enumerated() {
                    for (index, uniform) in members {
                        uniformLookupTable[uniform.name] = (index, uniform.dataType)
                    }
                }
            }
        }
        
        return (pipelineState, uniformLookupTable)
    } catch {
        fatalError("Could not create render pipeline state for vertex:\(vertexFunctionName), fragment:\(fragmentFunctionName), error:\(error)")
    }
}



extension MTLCommandBuffer {
    func renderQuad(pipelineState: MTLRenderPipelineState, uniform: [Float]? = nil, inputTextures:[UInt: MTLTexture], textureCoordinates: [Float], outputTexture: MTLTexture) {
        let positions:[Float] = [
            -1.0, 1.0,
             1.0, 1.0,
            -1.0,-1.0,
             1.0,-1.0]
        let vertexBuffer = sharedMetalRenderingDevice.device.makeBuffer(bytes: positions, length: positions.count * MemoryLayout<Float>.size, options: [])
        vertexBuffer?.label = "Vertices"
        
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = outputTexture
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1)
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].loadAction = .clear
        
        guard let renderEncoder = self.makeRenderCommandEncoder(descriptor: renderPass) else { fatalError("Could not create render encoder") }
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        for textureIndex in 0..<inputTextures.count {
            let currentTexture = inputTextures[UInt(textureIndex)]!
            let textureBuffer = sharedMetalRenderingDevice.device.makeBuffer(bytes: textureCoordinates, length: textureCoordinates.count * MemoryLayout<Float>.size, options: [])
            textureBuffer?.label = "Texture Coordinates"
            renderEncoder.setVertexBuffer(textureBuffer, offset: 0, index: 1 + textureIndex)
            renderEncoder.setFragmentTexture(currentTexture, index: textureIndex)
        }
        
        if let uniform = uniform {
            let uniformBuffer = sharedMetalRenderingDevice.device.makeBuffer(bytes: uniform, length: uniform.count * MemoryLayout<Float>.size, options: [])
            renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
    }
}


