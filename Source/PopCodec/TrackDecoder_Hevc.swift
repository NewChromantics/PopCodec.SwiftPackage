import CoreVideo
import Foundation
import Combine
import CoreMedia
//import PopH264
import SwiftUI
import VideoToolbox
//import PopCommon
import UniformTypeIdentifiers



public class HevcTrackDecoder : FrameFactory, TrackDecoder, ObservableObject
{
	public var subscriberCancellables: [AnyCancellable] = []
	
	var codec : HevcCodec
	
	init(codecMeta:HevcCodec,getFrameSampleAndDependencies:@escaping (Millisecond)async throws->Mp4SampleAndDependencies,getFrameData:@escaping (Mp4Sample)async throws->Data)
	{
		self.codec = codecMeta
	}
	
	public func GetDebugView() -> AnyView 
	{
		return AnyView(DebugView())
	}
	
	@ViewBuilder func DebugView() -> some View 
	{
		VStack
		{
			Text("Hevc track decoder")
		}
	}
	
	func LoadFrame(time: Millisecond) async throws -> AsyncDecodedFrame
	{
		throw PopCodecError("todo: HEVC loadframe()")
	}
	
	public func LoadFrame(time: Millisecond) -> AsyncDecodedFrame 
	{
		return AsyncDecodedFrame(frameTime: time)
	}
	
	public func HasCachedFrame(time: Millisecond) -> Bool 
	{
		return false
	}
	

}
