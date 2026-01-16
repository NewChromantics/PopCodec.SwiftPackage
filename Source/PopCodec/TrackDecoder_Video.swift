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
	@Published var decodedFrames : [FrameOrError] = []
	private var decodedFrameNumbersCache = Set<Millisecond>()	//	fast access to decodedFrames data

	//	async closures seem to be a problem, return a promise essentally
	var getFrameSampleAndDependencies : (Millisecond) -> Task<Mp4SampleAndDependencies,Error>
	var getFrameData : (Mp4Sample) -> Task<Data,Error>
	//var getFrameSample : (Millisecond) async throws -> Mp4Sample
	//var getFrameData : (Mp4Sample) async throws -> Data
	var maxRetainedFrames = 60

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
	
	
	private func AllocateDecoder(codecMeta:CodecType) async throws -> VideoDecoderType
	{
		return try VideoDecoderType(codecMeta: codecMeta, onFrameDecoded: OnFrameDecoded, onDecodeError: OnFrameError)
		//return try VideoToolboxH264Decoder(codecMeta:codecMeta,onFrameDecoded: OnFrameDecoded,onDecodeError: OnFrameError)
	}
	
	private func OnFrameError(presentationFrame:Millisecond,error:Error)
	{
		
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
	private func GetDecodedFrame(time:Millisecond) -> FrameOrError?
	{
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
		let frameRenderable = VideoAsyncDecodedFrame<FrameType>(presentationTime:time)
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
	public func DecodeFrame(time: Millisecond) async throws -> FrameType 
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
