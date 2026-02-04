import CoreVideo
import Foundation
import Combine
import CoreMedia
//import PopH264
import SwiftUI
import VideoToolbox
//import PopCommon
import UniformTypeIdentifiers

//	temporarily public for some direct access
public class VideoTrackDecoder<VideoDecoderType:VideoDecoder> : FrameFactory, TrackDecoder, ObservableObject
{
	typealias CodecType = VideoDecoderType.CodecType
	public typealias FrameType = VideoDecoderType.OutputFrameType
	typealias FrameOrError = VideoFrameOrError<FrameType>
	public var subscriberCancellables : [AnyCancellable] = []
	
	var allocateDecoderTask : Task<VideoDecoder,Error>!
	var allocatedDecoder : VideoDecoder?		//	for sync access
	@Published var decodedFrames : [FrameOrError] = []
	@MainActor private var decodedFrameNumbersCache = Set<Millisecond>()	//	fast access to decodedFrames data

	//	async closures seem to be a problem, return a promise essentally
	var getFrameSampleAndDependencies : (Millisecond) -> Task<Mp4SampleAndDependencies,Error>
	var getFrameData : (Mp4Sample) -> Task<Data,Error>
	//var getFrameSample : (Millisecond) async throws -> Mp4Sample
	//var getFrameData : (Mp4Sample) async throws -> Data
	var maxRetainedFrames = 200	//	seems like the ideal here is the count between keyframes, but we can't guess that. Need to balance with mem/resource usage

	init(codecMeta:CodecType,getFrameSampleAndDependencies:@escaping (Millisecond)async throws->Mp4SampleAndDependencies,getFrameData:@escaping (Mp4Sample)async throws->Data)
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
			Task
			{
				@MainActor in
				//	gr: decodedFrameNumbersCache needs a lock, writing and reading from different threads
				//print("Writing new decoded frame number cache x\(newValue.count)")
				self.decodedFrameNumbersCache = Set( newValue.map{ $0.presentationTime } )
			}
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
	
	public func GetDecodingFrames() -> [Millisecond] 
	{
		return allocatedDecoder?.GetPendingFrames() ?? []
	}
	
	private func AllocateDecoder(codecMeta:CodecType) async throws -> VideoDecoderType
	{
		let decoder = try VideoDecoderType(codecMeta: codecMeta, getFrameData:getFrameData, onFrameDecoded: OnFrameDecoded, onDecodeError: OnFrameError)
		self.allocatedDecoder = decoder
		return decoder
	}
	
	private func OnFrameError(presentationTime:Millisecond,error:Error)
	{
		//	dont replace a good frame with a bad frame
		//	and whether its good or bad, we'll ignore this error
		if let existingIndex = decodedFrames.firstIndex(where: {$0.presentationTime == presentationTime})
		{
			let existingFrame = decodedFrames[existingIndex]
			print("discarding duplicate frame \(presentationTime) (was error=\(existingFrame.hasError), now error=true)")
			return
		}
		print("Got new error frame \(presentationTime)")
		
		//	need to resolve pending fetches
		decodedFrames.append( .error((presentationTime,error)) )
		
		//	cull 
		CullOldDecodedFrames()
	}
	
	private func OnFrameDecoded(frame:FrameType)
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
		print("Got new frame \(frame.presentationTime)")
		
		//	need to pre-copy the struct to allow us to mutate
		var frameCopyForMutating = frame
		
		//	pre-fetch cgimage
		frameCopyForMutating.PreRenderWarmup()
		
		//	need to resolve pending fetches
		decodedFrames.append( .frame(frameCopyForMutating) )
		
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
	private func GetDecodedFrame(time:Millisecond) -> FrameOrError?
	{
		//	gr: expensive func as it's called a lot, but HasCachedFrame is isolated...
		return decodedFrames.first{ $0.presentationTime == time }
	}

	
	private func WaitForDecodedFrame(time:Millisecond) async throws -> FrameOrError
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
				print("Frame found \(time)")
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
				newValue in 
				//print("decoded frames completion")
				let selfExists = self.decodedFrames.first{ $0.presentationTime == time } != nil
				let newValueExists = newValue.first{ $0.presentationTime == time } != nil
				//print("Frame cache has changed (waiting for \(time)) selfExists=\(selfExists) newValueExists=\(newValueExists)")
				changedPromise(Result.success(Void()))
			}/*
			receiveValue:
			{
				newList in
				print("Frame cache has changed (waiting for \(time))")
				changedPromise(Result.success(Void()))
			}*/

			//	loop around and check again
			try await changedFuture.value
		}
		
	}
	
	@MainActor public func HasCachedFrame(time: Millisecond) -> Bool 
	{
		//	use cached
		//	crash here when reading and being set in another thread - need a safe sync read
		return decodedFrameNumbersCache.contains(time)
	}
	
	
	public func LoadFrame(time: Millisecond,priority:DecodePriority) -> AsyncDecodedFrame 
	{
		if let cached = GetDecodedFrame(time: time)
		{
			if let cachedFrame = try? cached.GetFrame()
			{
				let asyncFrame = VideoAsyncDecodedFrame<FrameType>(presentationTime:time,frame: cachedFrame)
				print("LoadFrame(\(time)) returning cached frame; ready=\(asyncFrame.isReady)")
				/*

				Task
				{
					@MainActor in
					asyncFrame.OnFrame(frame)
				}
				//print("LoadFrame(\(time)) returning cached frame ready=\(asyncFrame.isReady)")
				print("LoadFrame(\(time)) returning cached frame")
				 */
				return asyncFrame
			}
		}
		
		let asyncFrame = VideoAsyncDecodedFrame<FrameType>(presentationTime:time)
		Task
		{
			do
			{
				let frame = try await DecodeFrame(time: time,priority: priority)
				await asyncFrame.OnFrame(frame)
			}
			catch
			{
				await asyncFrame.OnError(error)
			}
		}
		return asyncFrame
	}
	
	//	if the time hasn't been resolved, the closest frame will be returned
	public func DecodeFrame(time: Millisecond,priority:DecodePriority) async throws -> FrameType 
	{
		async let decoderPromise = allocateDecoderTask.result
		
		//	get meta
		print("Decoding frame \(time)...")
		let sampleAndDependencies = try await self.getFrameSampleAndDependencies(time).value
		//print("\(time) -> \(sampleAndDependencies.samplesInDecodeOrder.map{"\($0.presentationTime)"})...")
		
		//	check if it's already decoded
		if let existingFrame = GetDecodedFrame(time: Millisecond(sampleAndDependencies.sample.presentationTime) )
		{
			return try existingFrame.GetFrame()
		}
		
		print("Getting frame \(time) dependencies...")
		var decodeSamples = sampleAndDependencies.samplesInDecodeOrder
		let decoder = try await decoderPromise.get()
		
		print("Submitting batch \(time) \(priority)...")
		try decoder.DecodeFrames(frames:decodeSamples,priority: priority)
		{
			//	do we still need to decode this?
			let targetFrameExists = await self.decodedFrameNumbersCache.contains(sampleAndDependencies.sample.presentationTime)
			//	todo: check for error to retry 
			return !targetFrameExists
		}		
		
		//	now wait for the frame to be spat out
		let resolvedTime = sampleAndDependencies.sample.presentationTime
		//print("Now WaitForDecodedFrame(\(time))...")
		print("Waiting for output frame \(time)...")
		let frame = try await WaitForDecodedFrame(time: resolvedTime)
		return try frame.GetFrame()
	}

}
