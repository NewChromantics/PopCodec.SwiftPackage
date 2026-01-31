import SwiftUI
import Combine

//	this returns a self-resolving frame (like a promise) and the decoder will fulfil it
//	rename FrameRenderable here to FramePromise?
public protocol TrackDecoder : ObservableObject, ObservableSubscribable
{
	func LoadFrame(time:Millisecond,priority:DecodePriority) -> AsyncDecodedFrame
	func HasCachedFrame(time:Millisecond) -> Bool		//	maybe we can return (FrameRenderable?) ?
	func GetDebugView() -> AnyView
	
	func GetDecodingFrames() -> [Millisecond]	//	can return AsyncDecodedFrames?
}

