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
}

class VideoToolboxDecoder<CodecType:Codec,OutputVideoFrame:VideoFrame> : VideoDecoder
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
	
	required init(codecMeta:CodecType,getFrameData:@escaping(Mp4Sample)->Task<Data,Error>,onFrameDecoded: @escaping (OutputVideoFrame) -> Void,onDecodeError:@escaping(Millisecond,Error)->Void) throws
	{
		self.getFrameData = getFrameData
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
		self.decodeThreadTask = Task(name:"DecodeThread",priority: .medium, operation: DecodeThread)
	}
	
	deinit
	{
		self.decodeThreadTask.cancel()
		//	free session
	}
	
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
				for frame in decodeBatch
				{
					//	we could pre-fetch these
					let data = try await getFrameData(frame).value
					try DecodeFrame(meta: frame, data: data)
				}
			}
			catch
			{
				print("todo: flush batch \(error.localizedDescription)")
				//	flush out the rest of the batch?
				//self.onDecodeError(next.0.presentationTime, error)
			}
		}
	}
	
	func DecodeFrames(frames:[Mp4Sample],priority:DecodePriority,frameStillRequired:@escaping()async->Bool) throws
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
	}
	
	
	private func DecodeFrame(meta:Mp4Sample,data:Data) throws
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
					if self.IsRestartSessionError(status)
					{
						print("Todo: restart decoder session")
					}
					
					let error : Error = VideoToolboxError(status,context:"Decode frame (decode time=\(meta.decodeTime))") ?? 
						PopCodecError("Missing image in decode")
					
					print("decode error(\(status.videoToolboxError)) - invalidate lastSubmitedDecodeTime(\(self.lastSubmitedDecodeTime))")
					self.lastSubmitedDecodeTime = nil
					self.onDecodeError(outputPresetentationMs,error)
					return
				}
				let frame = OutputVideoFrame(frameBuffer: imageBuffer, decodeTime: Millisecond(meta.decodeTime), presentationTime: outputPresetentationMs, duration:meta.duration)
				self.onFrameDecoded(frame)
			}
			if let error = VideoToolboxError(decodeFrameResult,context:"Decode frame (decode time=\(meta.decodeTime))")
			{
				throw error
			}
			print("Updating lastSubmitedDecodeTime to \(meta.decodeTime) - \(decodeFrameResult)")
			lastSubmitedDecodeTime = Millisecond(meta.decodeTime)
		}
		catch
		{
			self.onDecodeError(meta.presentationTime,error)
			throw error
		}
	}
	
	func IsRestartSessionError(_ error:OSStatus) -> Bool
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
