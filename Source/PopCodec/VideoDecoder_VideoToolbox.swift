import VideoToolbox
import CoreMedia
import PopCommon




public struct CoreVideoFrame : VideoFrame
{
	public var cgImage: CGImage		{	get throws {try frameBuffer.cgImage}	}
	public let frameBuffer : CVPixelBuffer
	public let decodeTime : Millisecond
	public let presentationTime : Millisecond
	public let duration : Millisecond
	
	public init(frameBuffer: CVPixelBuffer, decodeTime: Millisecond, presentationTime: Millisecond, duration:Millisecond) 
	{
		self.frameBuffer = frameBuffer
		self.decodeTime = decodeTime
		self.presentationTime = presentationTime
		self.duration = duration
	}
	
	public mutating func PreRenderWarmup() 
	{
		//	load cg frame once, and it'll load faster later?
		//cgImage = try? frameBuffer.cgImage
	}
}

//	core video input, but discards immediately and only stores a cgimage
public struct CGVideoFrame : VideoFrame
{
	public var cgImage: CGImage
	{
		get throws
		{
			if let cgImageLoadError
			{
				throw cgImageLoadError
			}
			return cgImageLoaded!
		}
	}
	var cgImageLoaded : CGImage?
	var cgImageLoadError : Error?
		
	public let decodeTime : Millisecond
	public let presentationTime : Millisecond
	public let duration : Millisecond
	
	public init(frameBuffer: CVPixelBuffer, decodeTime: Millisecond, presentationTime: Millisecond, duration:Millisecond)
	{
		do
		{
			self.cgImageLoaded = try frameBuffer.cgImage
		}
		catch
		{
			self.cgImageLoadError = error
		}
		self.decodeTime = decodeTime
		self.presentationTime = presentationTime
		self.duration = duration
	}
	
	public mutating func PreRenderWarmup() 
	{
	}
}


public class VideoAsyncDecodedFrame<FrameType:VideoFrame> : AsyncDecodedFrame
{
	@Published public var frame : FrameType? = nil
	@Published private var framePromise = SendablePromise<FrameType>()
	
	public init(presentationTime:Millisecond)
	{
		super.init(frameTime: presentationTime)
	}
	
	//	init for when we already have the frame loaded
	public init(presentationTime:Millisecond,frame:FrameType)
	{
		self.frame = frame
		super.init(frameTime: presentationTime,initiallyReady: true)
		//	make sure WaitForFrame() will succeed
		framePromise.Resolve(frame)
	}
	
	@MainActor func OnFrame(_ frame:FrameType)
	{
		print("OnFrame \(frame.presentationTime)")
		self.frame = frame
		framePromise.Resolve(frame)
		print("Finished setting .frame \(frame.presentationTime)")
	}
	
	@MainActor public override func OnError(_ error:Error)
	{
		super.OnError(error)
		framePromise.Reject(error)
	}

	public func WaitForFrame() async throws -> FrameType
	{
		if self.isReady && !framePromise.isResolved
		{
			throw PopCodecError("Error in state of async frame (is ready but not resolved)")
		}
		return try await framePromise.value
	}
	
}


extension Data 
{
	func toCMBlockBuffer() throws -> CMBlockBuffer 
	{
		func freeBlock(_ refCon: UnsafeMutableRawPointer?, doomedMemoryBlock: UnsafeMutableRawPointer, sizeInBytes: Int) -> Void 
		{
			let unmanagedData = Unmanaged<NSData>.fromOpaque(refCon!)
			unmanagedData.release()
		}
		
		
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
		
		if let error = CoreMediaBlockBufferError(result: result,context: "CMBlockBufferCreateWithMemoryBlock")
		{
			throw error
		}
		
		guard let blockBuffer else 
		{
			throw PopCodecError("CMBlockBufferCreateWithMemoryBlock succeeded but null buffer")
		}
		
		let blockDataLength = CMBlockBufferGetDataLength(blockBuffer)
		if blockDataLength != data.length
		{
			throw PopCodecError("CMBlockBufferCreateWithMemoryBlock succeeded but size (\(blockDataLength)) not expected size \(data.length)")
		}
		
		return blockBuffer
	}
}


public enum DecodePriority : Comparable
{
	case Highest		//	if something comes in with this, it reduces other highests to high
	case High
	case Low
}

struct DecodeBatch
{
	var priority : DecodePriority
	var frames : [Mp4Sample]
	var frameStillRequired : ()async->Bool	//	async for isolation, but maybe there's another need
	var promise = SendablePromise<any VideoFrame>()
	var targetPresentationFrameNumber : Millisecond		{	frames.last!.presentationTime	}
	
	func OnNoLongerRequired()
	{
		promise.Reject( PopCodecError("Batch no longer required") )
	}
}

actor VideoToolboxDecoder<CodecType:Codec,OutputVideoFrame:VideoFrame> : VideoDecoder
{
	var session : VTDecompressionSession
	var onFrameDecoded : (OutputVideoFrame)->Void
	var onDecodeError : (Millisecond,Error)->Void
	var format : CMVideoFormatDescription
	
	//	continue decoding when possible
	var lastSubmitedDecodeTime : Millisecond? = nil
	
	//	do these need to be individual batches?
	var decodeQueue : [DecodeBatch] = []
	var decodeThreadTask : Task<Void,Never>!
	var getFrameData : (Mp4Sample)->Task<Data,Error>
	
	init(codecMeta:CodecType,getFrameData:@escaping(Mp4Sample)->Task<Data,Error>,onFrameDecoded: @escaping (OutputVideoFrame) -> Void,onDecodeError:@escaping(Millisecond,Error)->Void) throws
	{
		self.getFrameData = getFrameData
		self.onFrameDecoded = onFrameDecoded
		self.onDecodeError = onDecodeError
		self.format = try codecMeta.GetFormat()
		
		var decoderParams : [CFString:Any] = [:]
		var destinationPixelBufferAttributes : [CFString:Any] = [:]
		
		destinationPixelBufferAttributes[kCVPixelBufferOpenGLCompatibilityKey] = true
		destinationPixelBufferAttributes[kCVPixelBufferMetalCompatibilityKey] = true
		
		//	bgra ios only
		//	gr: macos 26 (maybe before) now supports BGRA!
		destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_32BGRA	
		//destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_128RGBAFloat
		//destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
		//destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
		
		
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
		self.decodeThreadTask = Task(name:"DecodeThread",priority: .medium, operation: DecodeThread)
	}
	
	deinit
	{
		self.decodeThreadTask.cancel()
		//	free session
	}
	/*
	nonisolated func GetPendingFrames() -> [Millisecond] 
	{
		decodeQueue.flatMap
		{
			queue in
			return queue.frames.map{ $0.presentationTime }
		}
	}
	*/
	
	//	might need this to be private as we dont want caller to decide what to filter... although we do want to reduce fetching from file...
	private func FilterUnneccesaryDecodes(samples:[Mp4Sample]) -> ArraySlice<Mp4Sample>
	{
		//	if the last sample we decoded is in the list, we dont need to do the ones before it
		guard let lastSubmitedDecodeTime else
		{
			return ArraySlice(samples)
		}
		let lastDecodedIndex = samples.firstIndex{ $0.decodeTime == lastSubmitedDecodeTime }
		guard let lastDecodedIndex else
		{
			//	not in the list
			print("Decoding whole batch, \(samples.count) samples")
			return ArraySlice(samples)
		}
		
		let undecodedSamples = samples[lastDecodedIndex+1..<samples.count]
		print("Skip samples to \(lastDecodedIndex)... now decoding x\(undecodedSamples.count)")
		return undecodedSamples
	}
	
	func GetNaluDataLength(frameData:Data) -> Int?
	{
		guard let lengthSize = self.format.nalUnitHeaderLength else
		{
			return nil
		}
		let lengthBytes = frameData[0..<lengthSize]
		var lengthInData = 0
		for byte in lengthBytes
		{
			lengthInData <<= 8
			lengthInData |= Int(byte)
		}
		return lengthInData + lengthSize
	}
	
	private func PopNextBatch() async -> DecodeBatch?
	{
		//	todo: let batches that only need one decode go ahead of big batches?
		
		//	let batches that are ready, resolve
		//	gr: we dont need to run them atm, just remove them
		var keepQueue : [DecodeBatch] = []
		for batch in decodeQueue
		{
			let stillRequired = await batch.frameStillRequired()
			if stillRequired
			{
				keepQueue.append(batch)
			}
			else
			{
				//	this batch will be dropped
				batch.OnNoLongerRequired()
			}
		}
		decodeQueue = keepQueue
		
		if decodeQueue.isEmpty
		{
			return nil
		}
		
		//	FIFO but by priority
		var queuePrioritys = Set<DecodePriority>()
		decodeQueue.forEach{ queuePrioritys.insert( $0.priority ) }
		let highestPriority = queuePrioritys.sorted{ a,b in a > b }.first!
		
		//return decodeQueue.popFirst()
		let firstIndexWithHighestPriority = decodeQueue.firstIndex{ $0.priority == highestPriority }
		guard let firstIndexWithHighestPriority else
		{
			print("Queue missing batch with expected highest priority \(highestPriority)")
			return decodeQueue.popFirst()
		}
		
		let popped = decodeQueue[firstIndexWithHighestPriority]
		decodeQueue.remove(at: firstIndexWithHighestPriority)
		return popped
	}
	
	private func DecodeThread() async
	{
		//	wait for frames to change
		while !Task.isCancelled
		{
			//	filter unncessacry decodes here
			//	todo: if we do batches, verifiy keyframes
			guard let nextBatch = await PopNextBatch() else
			{
				await Task.sleep(milliseconds: 100)
				continue
			}
			
			let isStillRequired = await nextBatch.frameStillRequired()
			if !isStillRequired
			{
				print("Batch no longer required - skipping")
				continue
			}
			
			print("Decoding batch for \(nextBatch.frames.last!.presentationTime) priority=\(nextBatch.priority)")
			let decodeBatch = FilterUnneccesaryDecodes(samples: nextBatch.frames)
			
			do
			{
				var targetDecodedFrame : OutputVideoFrame?
				let targetPresentationTime = nextBatch.targetPresentationFrameNumber
				var decodedFrameNumbers : [Millisecond] = []
				
				for frame in decodeBatch
				{
					//	we could pre-fetch these
					let data = try await getFrameData(frame).value
					let frame = try await DecodeFrame(meta: frame, data: data)
					if frame.presentationTime == targetPresentationTime
					{
						targetDecodedFrame = frame
					}
					decodedFrameNumbers.append(frame.presentationTime)
				}
				guard let targetDecodedFrame else
				{
					let debugNumbers = decodedFrameNumbers.map{"\($0)"}.joined(separator: ", ")
					throw PopCodecError("Batch failed to decode target frame \(targetPresentationTime) (decoded \(debugNumbers))")
				}
				nextBatch.promise.Resolve(targetDecodedFrame)
			}
			catch
			{
				print("todo: flush batch \(error.localizedDescription)")
				//	flush out the rest of the batch?
				//self.onDecodeError(next.0.presentationTime, error)
				nextBatch.promise.Reject(error)
			}
		}
	}
	
	func DecodeFrames(frames:[Mp4Sample],priority:DecodePriority,frameStillRequired:@escaping()async->Bool) async throws -> OutputVideoFrame
	{
		let batch = DecodeBatch(priority: priority, frames: frames, frameStillRequired: frameStillRequired)
		
		//	if this new priority is highest, reduce all the other highests
		if priority == .Highest
		{
			decodeQueue.mutateEach
			{
				batch in
				if batch.priority == .Highest
				{
					print("Downgraded batch from highest to high")
					batch.priority = .High
				}
			}
		}
		
		decodeQueue.append(batch)
		//	wake up thread
		
		let decodedFrame = try await batch.promise.value
		guard let decodedTypedFrame = decodedFrame as? OutputVideoFrame else
		{
			throw PopCodecError("Decoded frame to wrong type")
		}
		return decodedTypedFrame
	}
	
	
	private func DecodeFrame(meta:Mp4Sample,data:Data) async throws -> OutputVideoFrame
	{
		do
		{
			//	avoid double decode
			if let lastSubmitedDecodeTime, lastSubmitedDecodeTime == meta.decodeTime
			{
				print("Attempted double decode of \(lastSubmitedDecodeTime)")
				throw PopCodecError("Attempted double decode of \(lastSubmitedDecodeTime) - and cannot get decoded frame")
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
			
			if let prefixSize = GetNaluDataLength(frameData:data)
			{
				if prefixSize != data.count
				{
					//throw PopCodecError("Frame data size is specified as \(prefixSize) but is \(data.count)")
					print("Frame data size is specified as \(prefixSize) but is \(data.count)")
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
			
			//	needs to be let to be sent to the @sendable
			let decodePromise = SendablePromise<OutputVideoFrame>()
			
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
					//	some errors that mean we need to restart the session
					if Self.IsRestartSessionError(status)
					{
						print("Todo: restart decoder session")
					}
					
					let error : Error = VideoToolboxError(status,context:"Decode frame (decode time=\(meta.decodeTime))") ?? 
						PopCodecError("Missing image in decode")
					
					decodePromise.Reject( error )
					return
				}
				let frame = OutputVideoFrame(frameBuffer: imageBuffer, decodeTime: Millisecond(meta.decodeTime), presentationTime: outputPresetentationMs, duration:meta.duration)
				decodePromise.Resolve(frame)
			}
			if let error = VideoToolboxError(decodeFrameResult,context:"Decode frame (decode time=\(meta.decodeTime))")
			{
				throw error
			}
			
			let frame = try await decodePromise.value
			self.onFrameDecoded(frame)
			
			print("Updating lastSubmitedDecodeTime to \(meta.decodeTime) - \(decodeFrameResult)")
			lastSubmitedDecodeTime = Millisecond(meta.decodeTime)
			return frame
		}
		catch
		{
			self.onDecodeError(meta.presentationTime,error)
			throw error
		}
	}
	
	static func IsRestartSessionError(_ error:OSStatus) -> Bool
	{
		switch error
		{
			//	gr: this might mean we're calculating dependencies wrong for hevc?
			//	https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/videotoolbox.c#L732
			case kVTVideoDecoderReferenceMissingErr:	return true
				
			case kVTVideoDecoderMalfunctionErr:	return true
			case kVTInvalidSessionErr:			return true
			
			default: 
				return false
		}
	}
}
