import Combine


protocol FrameFactory
{
	//	gr: is the output async, or is the load async.
	//		one or the other!
	func LoadFrame(time:Millisecond,priority:DecodePriority) async throws -> AsyncDecodedFrame
}



//	these are passed around & cached, so theyre objects instad of a protocol
open class AsyncDecodedFrame : ObservableObject
{
	//	presentation time, which should always exist and not change
	//	we're assuming this is resolved...
	public let frameTime : Millisecond
	@Published public var error : Error? = nil
	@Published public var isReady : Bool = false
	
	public init(frameTime:Millisecond,initiallyReady:Bool=false)
	{
		self.isReady = initiallyReady
		self.frameTime = frameTime
	}
	
	@MainActor public func OnError(_ error:Error)
	{
		self.error = error
	}
	
}
