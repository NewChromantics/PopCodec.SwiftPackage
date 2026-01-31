import Foundation
import Combine
import PopCommon
import SwiftUI

public extension Array
{
	mutating func removeFirst(where match:(Element)->Bool) throws
	{
		guard let index = try self.firstIndex(where: match) else
		{
			throw DataNotFound("No matching element")
		}
		self.remove(at: index)
	}
}

class TextTrackDecoder : TrackDecoder
{
	func GetDecodingFrames() -> [Millisecond] 
	{
		pendingFrames
	}
	
	@Published var pendingFrames : [Millisecond] = []
	
	var subscriberCancellables: [AnyCancellable] = []
	var getFrameSample : (Millisecond)async throws->Mp4Sample?
	var getFrameData : (Mp4Sample)async throws->Data
	
	init(getFrameSample:@escaping(Millisecond)async throws->Mp4Sample?,getFrameData:@escaping (Mp4Sample)async throws->Data)
	{
		self.getFrameData = getFrameData
		self.getFrameSample = getFrameSample
	}
	
	private func OnStartLoad(time:Millisecond,closure:()async throws->Void) async throws
	{
		pendingFrames.append(time)
		do
		{
			try await closure()
			try? pendingFrames.removeFirst{ $0 == time }
		}
		catch
		{
			try? pendingFrames.removeFirst{ $0 == time }
			throw error
		}
	}
	
	func LoadFrame(time: Millisecond, priority: DecodePriority) -> AsyncDecodedFrame 
	{
		var asyncFrame = TextAsyncDecodedFrame(presentationTime: time)
		Task
		{
			do
			{
				try await OnStartLoad(time:time)
				{
					let sample = try await getFrameSample(time)
					guard let sample else
					{
						await asyncFrame.OnError(DataNotFound("No sample at \(time)"))
						return
					}
					let data = try await getFrameData(sample)
					guard let dataString = String(data:data,encoding: .utf8) else
					{
						throw PopCodecError("Failed to turn text data into string")
					}
					await asyncFrame.OnFrame(dataString)
				}
			}
			catch
			{
				await asyncFrame.OnError(error)
			}
		}
		return asyncFrame
	}
	
	func HasCachedFrame(time: Millisecond) -> Bool 
	{
		false
	}
	
	public func GetDebugView() -> AnyView 
	{
		return AnyView(DebugView())
	}
	
	@ViewBuilder func DebugView() -> some View 
	{
		VStack
		{
			Text("I am a text track decoder")
		}
	}
}


public class TextAsyncDecodedFrame : AsyncDecodedFrame
{
	public typealias FrameType = String
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
		//print("OnFrame \(frame.presentationTime)")
		self.frame = frame
		framePromise.Resolve(frame)
		//print("Finished setting .frame \(frame.presentationTime)")
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
