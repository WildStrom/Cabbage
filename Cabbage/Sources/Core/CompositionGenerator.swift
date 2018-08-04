//
//  CompositionGenerator.swift
//  Cabbage
//
//  Created by Vito on 13/02/2018.
//  Copyright © 2018 Vito. All rights reserved.
//

import AVFoundation

public class CompositionGenerator {
    
    // MARK: - Public
    public var timeline: Timeline {
        didSet {
            needRebuildComposition = true
            needRebuildVideoComposition = true
            needRebuildAudioMix = true
        }
    }
    public var renderSize: CGSize? {
        didSet {
            needRebuildVideoComposition = true
        }
    }
    
    private var composition: AVComposition?
    private var videoComposition: AVVideoComposition?
    private var audioMix: AVAudioMix?
    
    private var needRebuildComposition: Bool = true
    private var needRebuildVideoComposition: Bool = true
    private var needRebuildAudioMix: Bool = true
    
    public init(timeline: Timeline) {
        self.timeline = timeline
    }
    
    public func buildPlayerItem() -> AVPlayerItem {
        let composition = buildComposition()
        let playerItem = AVPlayerItem(asset: composition)
        playerItem.videoComposition = buildVideoComposition()
        playerItem.audioMix = buildAudioMix()
        return playerItem
    }
    
    public func buildImageGenerator() -> AVAssetImageGenerator {
        let composition = buildComposition()
        let imageGenerator = AVAssetImageGenerator(asset: composition)
        imageGenerator.videoComposition = buildVideoComposition()
        
        return imageGenerator
    }
    
    public func buildExportSession(presetName: String) -> AVAssetExportSession? {
        let composition = buildComposition()
        let exportSession = AVAssetExportSession.init(asset: composition, presetName: presetName)
        exportSession?.videoComposition = buildVideoComposition()
        exportSession?.audioMix = buildAudioMix()
        exportSession?.outputURL = {
            let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
            let filename = ProcessInfo.processInfo.globallyUniqueString + ".mp4"
            return documentDirectory.appendingPathComponent(filename)
        }()
        exportSession?.outputFileType = AVFileType.mp4
        return exportSession
    }
    
    // MARK: - Build Composition
    
    @discardableResult
    public func buildComposition() -> AVComposition {
        if let composition = self.composition, !needRebuildComposition {
            return composition
        }
        
        resetSetupInfo()
        
        let composition = AVMutableComposition(urlAssetInitializationOptions: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var videoChannelTrackIDs: [Int: Int32] = [:]
        func getVideoTrackID(for index: Int) -> Int32 {
            if let trackID = videoChannelTrackIDs[index] {
                return trackID
            }
            let trackID = generateNextTrackID()
            videoChannelTrackIDs[index] = trackID
            return trackID
        }
        
        timeline.videoChannel.enumerated().forEach({ (offset, provider) in
            for index in 0..<provider.numberOfVideoTracks() {
                let trackID: Int32 = getVideoTrackID(for: index) + Int32((offset % 2 + 1) * 1000)
                if let compositionTrack = provider.videoCompositionTrack(for: composition, at: index, preferredTrackID: trackID) {
                    let info = mainVideoTrackInfo.first(where: { $0.track == compositionTrack })
                    if let info = info {
                        info.info.append(provider)
                    } else {
                        let info = TrackInfo.init(track: compositionTrack, info: [provider])
                        mainVideoTrackInfo.append(info)
                    }
                }
            }
        })
        
        var audioChannelTrackIDs: [Int: Int32] = [:]
        func getAudioTrackID(for index: Int) -> Int32 {
            if let trackID = audioChannelTrackIDs[index] {
                return trackID
            }
            let trackID = generateNextTrackID()
            audioChannelTrackIDs[index] = trackID
            return trackID
        }
        var previousAudioTransition: AudioTransition?
        timeline.audioChannel.enumerated().forEach { (offset, provider) in
            for index in 0..<provider.numberOfAudioTracks() {
                let trackID: Int32 = getAudioTrackID(for: index) + Int32((offset % 2 + 1) * 1000)
                if let compositionTrack = provider.audioCompositionTrack(for: composition, at: index, preferredTrackID: trackID) {
                    
                    let info = mainAudioTrackInfo.first(where: { $0.track == compositionTrack })
                    if let info = info {
                        info.info.append(provider)
                    } else {
                        let info = TrackInfo.init(track: compositionTrack, info: [provider])
                        mainAudioTrackInfo.append(info)
                    }
                }
            }
            
            
            if offset == 0 {
                if timeline.audioChannel.count > 1 {
                    audioTransitionInfo[offset] = (nil, provider.audioTransition)
                }
            } else if offset == timeline.audioChannel.count - 1 {
                audioTransitionInfo[offset] = (previousAudioTransition, nil)
            } else {
                audioTransitionInfo[offset] = (previousAudioTransition, provider.audioTransition)
            }
            previousAudioTransition = provider.audioTransition
        }
        
        timeline.overlays.forEach { (provider) in
            for index in 0..<provider.numberOfVideoTracks() {
                let trackID: Int32 = generateNextTrackID()
                if let compositionTrack = provider.videoCompositionTrack(for: composition, at: index, preferredTrackID: trackID) {
                    let info = TrackInfo.init(track: compositionTrack, info: provider)
                    overlayTrackInfo.append(info)
                }
            }
        }
        
        timeline.audios.forEach { (provider) in
            for index in 0..<provider.numberOfAudioTracks() {
                let trackID: Int32 = generateNextTrackID()
                if let compositionTrack = provider.audioCompositionTrack(for: composition, at: index, preferredTrackID: trackID) {
                    let info = TrackInfo.init(track: compositionTrack, info: provider)
                    audioTrackInfo.append(info)
                }
            }
        }
        self.composition = composition
        return composition
    }
    
    public func buildVideoComposition() -> AVVideoComposition? {
        if let videoComposition = self.videoComposition, !needRebuildVideoComposition {
            return videoComposition
        }
        buildComposition()
        
        var layerInstructions: [VideoCompositionLayerInstruction] = []
        
        mainVideoTrackInfo.forEach { info in
            info.info.forEach({ (provider) in
                let layerInstruction = VideoCompositionLayerInstruction.init(trackID: info.track.trackID, videoCompositionProvider: provider)
                layerInstruction.prefferdTransform = info.track.preferredTransform
                layerInstruction.timeRange = provider.timeRange
                layerInstruction.transition = provider.videoTransition
                layerInstructions.append(layerInstruction)
            })
        }
        
        overlayTrackInfo.forEach { (info) in
            let track = info.track
            let provider = info.info
            let layerInstruction = VideoCompositionLayerInstruction.init(trackID: track.trackID, videoCompositionProvider: provider)
            layerInstruction.prefferdTransform = track.preferredTransform
            layerInstruction.timeRange = provider.timeRange
            layerInstructions.append(layerInstruction)
        }
        
        layerInstructions.sort { (left, right) -> Bool in
            return left.timeRange.end < right.timeRange.end
        }
        
        // Create multiple instructions，each instructions contains layerInstructions whose time range have insection with instruction，
        // When rendering the frame, the instruction can quickly find layerInstructions
        let layerInstructionsSlices = calculateSlices(for: layerInstructions)
        let mainTrackIDs = mainVideoTrackInfo.map({ $0.track.trackID })
        let instructions: [VideoCompositionInstruction] = layerInstructionsSlices.map({ (slice) in
            let trackIDs = slice.1.map({ $0.trackID })
            let instruction = VideoCompositionInstruction(theSourceTrackIDs: trackIDs as [NSValue], forTimeRange: slice.0)
            instruction.layerInstructions = slice.1
            instruction.passingThroughVideoCompositionProvider = timeline.passingThroughVideoCompositionProvider
            instruction.mainTrackIDs = mainTrackIDs.filter({ trackIDs.contains($0) })
            return instruction
        })
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = {
            if let renderSize = renderSize {
                return renderSize
            }
           let size =  mainVideoTrackInfo.reduce(CGSize.zero, { (size, info) -> CGSize in
                let trackSize = info.track.naturalSize.applying(info.track.preferredTransform)
                return CGSize(width: max(abs(trackSize.width), size.width),
                              height: max(abs(trackSize.height), size.height))
            })
            return size
        }()
        videoComposition.instructions = instructions
        videoComposition.customVideoCompositorClass = VideoCompositor.self
        self.videoComposition = videoComposition
        
        return videoComposition
    }
    
    public func buildAudioMix() -> AVAudioMix? {
        if let audioMix = self.audioMix, !needRebuildAudioMix {
            return audioMix
        }
        
        buildComposition()
        
        var audioParameters = [AVMutableAudioMixInputParameters]()
        
        mainAudioTrackInfo.forEach { (info) in
            let track = info.track
            let inputParameter = AVMutableAudioMixInputParameters(track: track)
            info.info.forEach({ (provider) in
                provider.configure(audioMixParameters: inputParameter)
                
                if let index = timeline.audioChannel.index(where: { $0 === provider }) {
                    if let transitions = audioTransitionInfo[index] {
                        if let segment = track.segments.first(where: { $0.timeMapping.target == provider.timeRange }) {
                            let targetTimeRange = segment.timeMapping.target
                            if let transition = transitions.0 {
                                transition.applyNextAudioMixInputParameters(inputParameter, timeRange: targetTimeRange)
                            }
                            if let transition = transitions.1 {
                                transition.applyPreviousAudioMixInputParameters(inputParameter, timeRange: targetTimeRange)
                            }
                        }
                    }
                }
            })
            audioParameters.append(inputParameter)
        }
        
        audioTrackInfo.forEach { (info) in
            let track = info.track
            let provider = info.info
            let inputParameter = AVMutableAudioMixInputParameters(track: track)
            provider.configure(audioMixParameters: inputParameter)
            audioParameters.append(inputParameter)
        }
        
        if audioParameters.count == 0 {
            return nil
        }
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters
        self.audioMix = audioMix
        return audioMix
    }
    
    // MARK: - Helper
    
    private var increasementTrackID: Int32 = 0
    private func generateNextTrackID() -> Int32 {
        let trackID = increasementTrackID + 1
        increasementTrackID = trackID
        return trackID
    }
    
    private var mainVideoTrackInfo: [TrackInfo<[TransitionableVideoProvider]>] = []
    private var mainAudioTrackInfo: [TrackInfo<[TransitionableAudioProvider]>] = []
    private var overlayTrackInfo: [TrackInfo<VideoProvider>] = []
    private var audioTrackInfo: [TrackInfo<AudioProvider>] = []
    private var audioTransitionInfo: [Int: (AudioTransition?, AudioTransition?)] = [:]
    
    private func resetSetupInfo() {
        increasementTrackID = 0
        mainVideoTrackInfo = []
        mainAudioTrackInfo = []
        overlayTrackInfo = []
        audioTrackInfo = []
        audioTransitionInfo = [:]
    }
    
    private func calculateSlices(for layerInstructions: [VideoCompositionLayerInstruction]) -> [(CMTimeRange, [VideoCompositionLayerInstruction])] {
        var layerInstructionsSlices: [(CMTimeRange, [VideoCompositionLayerInstruction])] = []
        layerInstructions.forEach { (layerInstruction) in
            var slices = layerInstructionsSlices
            
            var leftTimeRanges: [CMTimeRange] = [layerInstruction.timeRange]
            layerInstructionsSlices.enumerated().forEach({ (offset, slice) in
                let intersectionTimeRange = slice.0.intersection(layerInstruction.timeRange)
                if intersectionTimeRange.duration.seconds > 0 {
                    slices.remove(at: offset)
                    let sliceTimeRanges = CMTimeRange.sliceTimeRanges(for: layerInstruction.timeRange, timeRange2: slice.0)
                    sliceTimeRanges.forEach({ (timeRange) in
                        if slice.0.containsTimeRange(timeRange) && layerInstruction.timeRange.containsTimeRange(timeRange) {
                            let newSlice = (timeRange, slice.1 + [layerInstruction])
                            slices.append(newSlice)
                            leftTimeRanges = leftTimeRanges.flatMap({ (leftTimeRange) -> [CMTimeRange] in
                                return leftTimeRange.substruct(timeRange)
                            })
                        } else if slice.0.containsTimeRange(timeRange) {
                            let newSlice = (timeRange, slice.1)
                            slices.append(newSlice)
                        }
                    })
                }
            })
            
            leftTimeRanges.forEach({ (timeRange) in
                slices.append((timeRange, [layerInstruction]))
            })
            
            layerInstructionsSlices = slices
        }
        return layerInstructionsSlices
    }
    
    private class TrackInfo<T> {
        var track: AVCompositionTrack
        var info: T
        init(track: AVCompositionTrack, info: T) {
            self.track = track
            self.info = info
        }
    }
    
}

// MARK: -

extension AVMutableAudioMixInputParameters {
    private static var audioProcessingTapHolderKey: UInt8 = 0
    var audioProcessingTapHolder: AudioProcessingTapHolder? {
        get {
            return objc_getAssociatedObject(self, &AVMutableAudioMixInputParameters.audioProcessingTapHolderKey) as? AudioProcessingTapHolder
        }
        set(newValue) {
            objc_setAssociatedObject(self, &AVMutableAudioMixInputParameters.audioProcessingTapHolderKey, newValue, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN)
            audioTapProcessor = newValue?.tap
        }
    }
    
    func appendAudioProcessNode(_ node: AudioProcessingNode) {
        if audioProcessingTapHolder == nil {
            audioProcessingTapHolder = AudioProcessingTapHolder()
        }
        audioProcessingTapHolder?.audioProcessingChain.nodes.append(node)
    }
}

