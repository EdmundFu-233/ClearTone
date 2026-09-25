import Foundation
import Accelerate
import AVFoundation

/// 频谱分析器：使用 Accelerate/vDSP 进行 FFT
/// 说明：MTAudioProcessingTap 对 HTTPS 远程流媒体的支持有限，当前版本标记为不可用并回退到环境动画
public actor SpectrumAnalyzer {
    private nonisolated(unsafe) var fftSetup: OpaquePointer?
    private let fftSize = 1024
    private let bandCount = 64
    private var window: [Float]

    public private(set) var isAvailable: Bool = false
    public private(set) var failureReason: String?

    public init() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), vDSP_DFT_Direction.FORWARD)
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        // OpaquePointer 是 vDSP_DFT_Setup，在 deinit 中直接销毁
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
    }

    private func executeFFT(real: inout [Float], imag: inout [Float], realOut: inout [Float], imagOut: inout [Float]) {
        guard let setup = fftSetup else { return }
        vDSP_DFT_Execute(setup, &real, &imag, &realOut, &imagOut)
    }

    /// MTAudioProcessingTap 验证：对远程流媒体支持有限，当前版本回退
    public func attach(to playerItem: AVPlayerItem) async throws {
        failureReason = "MTAudioProcessingTap 对 HTTPS 远程流媒体支持有限，当前版本使用环境动画"
        isAvailable = false
        throw MusicError.unsupportedFormat("远程流媒体频谱暂不支持")
    }

    /// 处理 PCM 数据并返回频谱带（用于本地文件或已验证路径）
    public func process(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return Array(repeating: 0, count: bandCount)
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else {
            return Array(repeating: 0, count: bandCount)
        }

        // 应用窗函数
        var real = [Float](repeating: 0, count: fftSize)
        var imag = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(channelData[0], 1, window, 1, &real, 1, vDSP_Length(fftSize))

        // 执行 FFT
        var realOut = [Float](repeating: 0, count: fftSize)
        var imagOut = [Float](repeating: 0, count: fftSize)

        executeFFT(real: &real, imag: &imag, realOut: &realOut, imagOut: &imagOut)

        // 计算幅度（取前一半）
        let halfSize = fftSize / 2
        var magnitudes = [Float](repeating: 0, count: halfSize)
        realOut.withUnsafeMutableBufferPointer { realPtr in
            imagOut.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // 对数频带映射
        var bands = [Float](repeating: 0, count: bandCount)
        let minFreq: Float = 20
        let maxFreq: Float = 20000
        let sampleRate: Float = 44100

        for i in 0..<bandCount {
            let freqLow = minFreq * pow(maxFreq / minFreq, Float(i) / Float(bandCount))
            let freqHigh = minFreq * pow(maxFreq / minFreq, Float(i + 1) / Float(bandCount))

            let binLow = max(0, Int(freqLow * Float(fftSize) / sampleRate))
            let binHigh = min(Int(freqHigh * Float(fftSize) / sampleRate), halfSize - 1)

            if binLow < binHigh {
                var sum: Float = 0
                vDSP_sve(Array(magnitudes[binLow...binHigh]), 1, &sum, vDSP_Length(binHigh - binLow))
                bands[i] = sum / Float(binHigh - binLow)
            }
        }

        // 归一化
        var maxVal: Float = 0
        vDSP_maxv(bands, 1, &maxVal, vDSP_Length(bandCount))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(bands, 1, &scale, &bands, 1, vDSP_Length(bandCount))
        }

        // 静音衰减
        for i in 0..<bands.count {
            if bands[i] < 0.01 { bands[i] = 0 }
        }

        return bands
    }
}
