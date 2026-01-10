import CoreVideo
import Foundation
import Combine
import CoreMedia
//import PopH264
import SwiftUI
import VideoToolbox
//import PopCommon
import UniformTypeIdentifiers



public class H264AsyncDecodedFrame : AsyncDecodedFrame
{
	@Published public var frame : H264Frame? = nil
	
	public init(presentationTime:Millisecond)
	{
		super.init(frameTime: presentationTime)
	}
	
	@MainActor func OnFrame(_ frame:H264Frame)
	{
		print("OnFrame \(frame.presentationTime)")
		self.frame = frame
		print("Finished setting .frame \(frame.presentationTime)")
	}
}


//	this returns a self-resolving frame (like a promise) and the decoder will fulfil it
//	rename FrameRenderable here to FramePromise?
public protocol TrackDecoder : ObservableObject, ObservableSubscribable
{
	func LoadFrame(time:Millisecond) -> AsyncDecodedFrame
	func HasCachedFrame(time:Millisecond) -> Bool		//	maybe we can return (FrameRenderable?) ?
	func GetDebugView() -> AnyView
}



public struct H264Frame
{
	public let frameBuffer : CVPixelBuffer
	public let decodeTime : Millisecond
	public let presentationTime : Millisecond
	public let duration : Millisecond
	
	init(frameBuffer: CVPixelBuffer, decodeTime: Millisecond, presentationTime: Millisecond, duration:Millisecond) 
	{
		self.frameBuffer = frameBuffer
		self.decodeTime = decodeTime
		self.presentationTime = presentationTime
		self.duration = duration
	}

}


protocol H264Decoder
{
	var onFrameDecoded : (H264Frame)->Void			{	get	}
	var onDecodeError : (Millisecond,Error)->Void	{	get	}
	init(codecMeta:H264Codec,onFrameDecoded: @escaping (H264Frame) -> Void,onDecodeError:@escaping(Millisecond,Error)->Void) throws

	//	to save re-decoding, filter out the samples we dont need to re-decode from the current state
	func FilterUnneccesaryDecodes(samples:[Mp4Sample]) -> [Mp4Sample]
	func DecodeFrame(meta:Mp4Sample,data:Data) throws
}	
/*
class PopH264Decoder : H264Decoder
{
	var instance : PopH264Instance
	var onFrameDecoded : (H264Frame)->Void
	
	var frameUid : Int32 = 100
	var pendingFrames : [Int32:Mp4Sample] = [:]
	
	required init(codecMeta:H264Codec,onFrameDecoded: @escaping (H264Frame) -> Void) throws
	{
		self.onFrameDecoded = onFrameDecoded
		self.instance = PopH264Instance()
		
		guard let sps = codecMeta.sps.first else
		{
			throw AppError("Missing SPS")
		}
		guard let pps = codecMeta.pps.first else
		{
			throw AppError("Missing PPS")
		}
		
		let naluPrefix : [UInt8] = [0,0,0,1]
		let spsNalu = naluPrefix + sps
		let ppsNalu = naluPrefix + pps
		
		self.instance.PushData(data: Data(spsNalu), frameNumber: 0)
		self.instance.PushData(data: Data(ppsNalu), frameNumber: 0)
	
		//	look for error
		let peekMeta = self.instance.PeekNextFrame()
		if let error = peekMeta.Error
		{
			throw AppError("H264 init error \(error)")
		}
	}
	
	func FilterUnneccesaryDecodes(samples:[Mp4Sample]) -> [Mp4Sample]
	{
		return samples
	}

	func DecodeFrame(meta:Mp4Sample,data:Data)
	{
		self.frameUid += 1
		pendingFrames[frameUid] = meta
		self.instance.PushData(data: data, frameNumber: frameUid)
	}
}
*/

class VideoToolboxH264Decoder : H264Decoder
{
	var session : VTDecompressionSession
	var onFrameDecoded : (H264Frame)->Void
	var onDecodeError : (Millisecond,Error)->Void
	var format : CMVideoFormatDescription
	
	//	continue decoding when possible
	var lastSubmitedDecodeTime : Millisecond? = nil
	
	required init(codecMeta:H264Codec,onFrameDecoded: @escaping (H264Frame) -> Void,onDecodeError:@escaping(Millisecond,Error)->Void) throws
	{
		self.onFrameDecoded = onFrameDecoded
		self.onDecodeError = onDecodeError
		self.format = try codecMeta.GetFormat()
		
		var decoderParams : [CFString:Any] = [:]
		var destinationPixelBufferAttributes : [CFString:Any] = [:]
		
		destinationPixelBufferAttributes[kCVPixelBufferOpenGLCompatibilityKey] = true
		destinationPixelBufferAttributes[kCVPixelBufferMetalCompatibilityKey] = true
		destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_32BGRA	//	bgra ios only
		//destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
		
		var session : VTDecompressionSession?
		let result = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: decoderParams as CFDictionary, imageBufferAttributes: destinationPixelBufferAttributes as CFDictionary, decompressionSessionOut: &session)
		if result != S_OK || session == nil
		{
			throw PopCodecError("Failed to create decompression session \(result)")
		}
		guard let session else
		{
			throw PopCodecError("Failed to create decompression session (null session)")
		}			
		self.session = session
	}
	
	func FilterUnneccesaryDecodes(samples:[Mp4Sample]) -> [Mp4Sample]
	{
		//	if the last sample we decoded is in the list, we dont need to do the ones before it
		guard let lastSubmitedDecodeTime else
		{
			return samples
		}
		let lastDecodedIndex = samples.firstIndex{ $0.decodeTime == lastSubmitedDecodeTime }
		guard let lastDecodedIndex else
		{
			//	not in the list
			print("Decode all samples")
			return samples
		}

		let undecodedSamples = samples[lastDecodedIndex+1..<samples.count]
		print("Skip samples to \(lastDecodedIndex)... now decoding x\(undecodedSamples.count)")
		return Array(undecodedSamples)
	}
	
	func DecodeFrame(meta:Mp4Sample,data:Data) throws
	{
		do
		{
			//	avoid double decode
			if let lastSubmitedDecodeTime, lastSubmitedDecodeTime == meta.decodeTime
			{
				print("Attempted double decode of \(lastSubmitedDecodeTime)")
				return
			}
			
			//	don't go backwards, unless the new one is a keyframe
			//	gr; will this fail, or produce garbage (allow garbage motion for fun!)
			if let lastSubmitedDecodeTime, meta.decodeTime < lastSubmitedDecodeTime
			{
				if !meta.isKeyframe
				{
					throw PopCodecError("Decoding backwards without jumping to a keyframe, expect corruption/failure")
				}
			}
				
			
			let blockBuffer = try data.toCMBlockBuffer()
			
			var size = data.count
			var sampleBuffer: CMSampleBuffer? = nil
			let presentationTime = CMTime(value: CMTimeValue(meta.presentationTime), timescale: 1000)
			let decodeTime = CMTime(value: CMTimeValue(meta.decodeTime), timescale: 1000)
			let duration = CMTime(value: CMTimeValue(meta.duration), timescale: 1000)
			
			//	double check conversion
			let testPresentationTime = presentationTime.milliseconds
			let testDecodeTime = decodeTime.milliseconds
			if testPresentationTime != meta.presentationTime
			{
				throw PopCodecError("Time conversion has mismatched; \(meta.presentationTime) -> \(testPresentationTime)")
			}
			if testDecodeTime != meta.decodeTime
			{
				throw PopCodecError("Time conversion has mismatched; \(meta.decodeTime) -> \(testDecodeTime)")
			}
			
			var timingInfo: CMSampleTimingInfo = CMSampleTimingInfo(
				duration: duration,
				presentationTimeStamp: presentationTime,
				decodeTimeStamp: decodeTime
			)
			
			let createSampleBufferResult = CMSampleBufferCreateReady(
				allocator: kCFAllocatorDefault,
				dataBuffer: blockBuffer,
				formatDescription: format,
				sampleCount: 1,
				sampleTimingEntryCount: 1,
				sampleTimingArray: &timingInfo,
				sampleSizeEntryCount: 1,
				sampleSizeArray: &size,
				sampleBufferOut: &sampleBuffer
			)
			guard let sampleBuffer else
			{
				throw PopCodecError("failed to create sample buffer (\(createSampleBufferResult))")
			}
			let decodeFlags = VTDecodeFrameFlags()
			var decodeInfoFlags = VTDecodeInfoFlags()
			
			print("Decode frame \(meta.presentationTime) (decode=\(meta.decodeTime)) keyframe=\(meta.isKeyframe)")
			
			
			let decodeFrameResult = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: decodeFlags, infoFlagsOut: &decodeInfoFlags)
			{
				status, flags, imageBuffer, taggedBuffers, presentationTime, duration in
				let outputPresetentationMs = presentationTime.milliseconds
				let inputPresentationTimeMs = Millisecond(meta.presentationTime)
				if inputPresentationTimeMs != outputPresetentationMs
				{
					print("Decoded frame \(outputPresetentationMs) (vs input \(inputPresentationTimeMs)) result=\(status)")
				}
				
				//	if error and is lastDecodeTime, do we need to invalidate it?
				
				guard let imageBuffer else
				{
					print("decode error - invalidate lastSubmitedDecodeTime(\(self.lastSubmitedDecodeTime))")
					self.lastSubmitedDecodeTime = nil
					self.onDecodeError(outputPresetentationMs,PopCodecError("Failed to decode frame status=\(status)"))
					return
				}
				let frame = H264Frame(frameBuffer: imageBuffer, decodeTime: Millisecond(meta.decodeTime), presentationTime: outputPresetentationMs, duration:meta.duration)
				self.onFrameDecoded(frame)
			}
			print("Updating lastSubmitedDecodeTime to \(meta.decodeTime)")
			lastSubmitedDecodeTime = Millisecond(meta.decodeTime)
		}
		catch
		{
			self.onDecodeError(meta.presentationTime,error)
		}
	}
}


extension Data {
	func toCMBlockBuffer() throws -> CMBlockBuffer {
		var blockBuffer: CMBlockBuffer?
		let data: NSMutableData = .init(data: self)
		var source: CMBlockBufferCustomBlockSource = .init()
		
		source.refCon = Unmanaged.passRetained(data).toOpaque()
		source.FreeBlock = freeBlock
		
		let result = CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault,
			memoryBlock: data.mutableBytes,
			blockLength: data.length,
			blockAllocator: kCFAllocatorNull,
			customBlockSource: &source,
			offsetToData: 0,
			dataLength: data.length,
			flags: 0,
			blockBufferOut: &blockBuffer
		)
		
		if OSStatus(result) != kCMBlockBufferNoErr {
			throw CMEncodingError.cmBlockCreationFailed
		}
		
		guard let buffer = blockBuffer else {
			throw CMEncodingError.cmBlockCreationFailed
		}
		
		assert(CMBlockBufferGetDataLength(buffer) == data.length)
		
		return buffer
	}
}

private func freeBlock(_ refCon: UnsafeMutableRawPointer?, doomedMemoryBlock: UnsafeMutableRawPointer, sizeInBytes: Int) -> Void {
	let unmanagedData = Unmanaged<NSData>.fromOpaque(refCon!)
	unmanagedData.release()
}

enum CMEncodingError: Error {
	case cmBlockCreationFailed
}


enum H264FrameOrError
{
	case frame(H264Frame),
		 error((Millisecond,Error))
	
	var presentationTime : Millisecond
	{
		switch self
		{
			case .error(let (time,error)):	return time
			case .frame(let frame):			return frame.presentationTime
		}
	}
	
	var hasError : Bool
	{
		switch self
		{
			case .error(_):	return true
			default:		return false
		}
	}
	
	//	throws error if this is an error
	func GetFrame() throws -> H264Frame
	{
		switch self
		{
			case .error(let (time,error)):	throw error
			case .frame(let frame):			return frame
		}
	}
}


//	temporarily public for some direct access
public class H264TrackDecoder : FrameFactory, TrackDecoder, ObservableObject
{
	public var subscriberCancellables : [AnyCancellable] = []
	
	var allocateDecoderTask : Task<H264Decoder,Error>!
	@Published var decodedFrames : [H264FrameOrError] = []
	private var decodedFrameNumbersCache = Set<Millisecond>()	//	fast access to decodedFrames data

	//	async closures seem to be a problem, return a promise essentally
	var getFrameSampleAndDependencies : (Millisecond) -> Task<Mp4SampleAndDependencies,Error>
	var getFrameData : (Mp4Sample) -> Task<Data,Error>
	//var getFrameSample : (Millisecond) async throws -> Mp4Sample
	//var getFrameData : (Mp4Sample) async throws -> Data
	var maxRetainedFrames = 60

	init(codecMeta:H264Codec,getFrameSampleAndDependencies:@escaping (Millisecond)async throws->Mp4SampleAndDependencies,getFrameData:@escaping (Mp4Sample)async throws->Data)
	{
		//self.getFrameData = getFrameData
		//self.getFrameSample = getFrameSample
		
		self.getFrameSampleAndDependencies = {
			time in
			return Task{	try await getFrameSampleAndDependencies(time)	}
		}
		self.getFrameData = {
			sample in
			return Task{	try await getFrameData(sample)	}
		}
		
		self.allocateDecoderTask = Task
		{
			try await AllocateDecoder(codecMeta: codecMeta)
		}
		
		//	auto cache the frame numbers in the decoded frames list
		let decodedFrameNumbersCacheObserver = _decodedFrames.projectedValue.sink
		{
			newValue in
			//print("Writing new decoded frame number cache x\(newValue.count)")
			self.decodedFrameNumbersCache = Set( newValue.map{ $0.presentationTime } )
		}
		subscriberCancellables.append(decodedFrameNumbersCacheObserver)
	}
	
	public func GetDebugView() -> AnyView 
	{
		return AnyView(DebugView())
	}
	
	@ViewBuilder func DebugView() -> some View 
	{
		VStack
		{
			Text("Decoded frame count x\(decodedFrames.count)")
		}
	}
	
	
	private func AllocateDecoder(codecMeta:H264Codec) async throws -> H264Decoder
	{
		return try VideoToolboxH264Decoder(codecMeta:codecMeta,onFrameDecoded: OnFrameDecoded,onDecodeError: OnFrameError)
	}
	
	private func OnFrameError(presentationFrame:Millisecond,error:Error)
	{
		
	}
	
	private func OnFrameDecoded(frame:H264Frame)
	{
		//	overwriting old frames makes sense, but the cache the FrameRenderer has will retain it
		//	so we're going to skip new frames!
		if let existingIndex = decodedFrames.firstIndex(where: {$0.presentationTime == frame.presentationTime})
		{
			//	if we're replacing an error with a good frame, keep the new one
			if !decodedFrames[existingIndex].hasError
			{
				print("discarding duplicate frame \(frame.presentationTime)")
				//	move this frame back up to the end of the array so it's last to get culled
				decodedFrames.move(fromOffsets: IndexSet(integer: existingIndex), toOffset: decodedFrames.count)
				return
			}
		}
		
		//	need to resolve pending fetches
		decodedFrames.append( .frame(frame) )
		
		//	cull 
		CullOldDecodedFrames()
	}
	
	func CullOldDecodedFrames()
	{
		if decodedFrames.count <= maxRetainedFrames
		{
			return
		}
		//	remove oldest frames
		let cullCount = decodedFrames.count - maxRetainedFrames
		decodedFrames.removeSubrange(0..<cullCount)
	}
	
	//	get cached frame if its there
	private func GetDecodedFrame(time:Millisecond) -> H264FrameOrError?
	{
		return decodedFrames.first{ $0.presentationTime == time }
	}

	
	private func WaitForDecodedFrame(time:Millisecond) async throws -> H264FrameOrError
	{
		var listener : AnyCancellable?

		//	adding a timeout to try and help identify bugs, but also not get stuck when there's decoding problems
		let startWaitTime = Date.now
		let timeout = TimeInterval(10)//	secs
		func CheckForTimeout() throws
		{
			let elapsed = Date.now.timeIntervalSince(startWaitTime)
			if elapsed < timeout
			{
				return
			}
			throw PopCodecError("Timeout(\(elapsed)) waiting for frame \(time)")
		}
		
		while true
		{
			try CheckForTimeout()
			
			if let frame = GetDecodedFrame(time: time)
			{
				return frame
			}
			
			//	wait for cache to change
			var changedPromise : Future<Void,Error>.Promise!
			let changedFuture = Future<Void,Error>()
			{
				promise in
				changedPromise = promise
			}
			
			//func resolve()	{	exportPromise(Result.success(123))	}
			//func reject(_ error:Error)	{	exportPromise(Result.failure(error))	}
			
			listener = _decodedFrames.projectedValue.sink
			{
				_ in 
				print("decoded frames completion")
			}
			receiveValue:
			{
				newList in
				print("Frame cache has changed (waiting for \(time))")
				changedPromise(Result.success(Void()))
			}

			//	loop around and check again
			try await changedFuture.value
		}
		
	}
	
	public func HasCachedFrame(time: Millisecond) -> Bool 
	{
		//	use cached
		return decodedFrameNumbersCache.contains(time)
		let match = decodedFrames.first{ $0.presentationTime == time }
		return match != nil
	}
	
	
	public func LoadFrame(time: Millisecond) -> AsyncDecodedFrame 
	{
		let frameRenderable = H264AsyncDecodedFrame(presentationTime:time)
		Task
		{
			do
			{
				let frame = try await DecodeFrame(time: time)
				await frameRenderable.OnFrame(frame)
			}
			catch
			{
				await frameRenderable.OnError(error)
			}
		}
		return frameRenderable
	}
	
	//	if the time hasn't been resolved, the closest frame will be returned
	public func DecodeFrame(time: Millisecond) async throws -> H264Frame 
	{
		async let decoderPromise = allocateDecoderTask.result
		
		//	get meta
		print("Fetching \(time)...")
		let sampleAndDependencies = try await self.getFrameSampleAndDependencies(time).value
		//print("\(time) -> \(sampleAndDependencies.samplesInDecodeOrder.map{"\($0.presentationTime)"})...")
		
		//	check if it's already decoded
		if let existingFrame = GetDecodedFrame(time: Millisecond(sampleAndDependencies.sample.presentationTime) )
		{
			return try existingFrame.GetFrame()
		}
		
		var decodeSamples = sampleAndDependencies.samplesInDecodeOrder
		let decoder = try await decoderPromise.get()
		decodeSamples = decoder.FilterUnneccesaryDecodes(samples:decodeSamples)
		
		//	decode in order
		for sample in decodeSamples
		{
			//	fetch data, decode
			let data = try await getFrameData(sample).value
			try decoder.DecodeFrame(meta:sample,data:data)
		}
		
		//	now wait for the frame to be spat out
		let resolvedTime = sampleAndDependencies.sample.presentationTime
		//print("Now WaitForDecodedFrame(\(time))...")
		let frame = try await WaitForDecodedFrame(time: resolvedTime)
		return try frame.GetFrame()
	}
	
}
