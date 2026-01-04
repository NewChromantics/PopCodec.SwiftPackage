import Combine


protocol FrameFactory
{
	//	gr: is the output async, or is the load async.
	//		one or the other!
	func LoadFrame(time:Millisecond) async throws -> AsyncDecodedFrame
}



open class AsyncDecodedFrame : ObservableObject
{
	//	presentation time, which should always exist and not change
	//	we're assuming this is resolved...
	let frameTime : Millisecond
	@Published public var error : Error? = nil
	
	public init(frameTime:Millisecond) 
	{
		self.frameTime = frameTime
	}
	
	@MainActor public func OnError(_ error:Error)
	{
		self.error = error
	}
	
}
