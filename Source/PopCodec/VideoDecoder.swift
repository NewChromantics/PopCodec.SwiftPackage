import Foundation



public protocol VideoFrame
{
	var presentationTime : Millisecond	{get}
}

enum VideoFrameOrError<VideoFrameType:VideoFrame>
{
	case frame(VideoFrameType),
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
	func GetFrame() throws -> VideoFrameType
	{
		switch self
		{
			case .error(let (time,error)):	throw error
			case .frame(let frame):			return frame
		}
	}
}



public protocol VideoDecoder
{
	associatedtype CodecType : Codec
	associatedtype OutputFrameType : VideoFrame	//	decoded frame type
	typealias InputFrameMeta = Mp4Sample	//	may want to change this in future, so alias now
	
	var onFrameDecoded : (OutputFrameType)->Void			{	get	}
	var onDecodeError : (Millisecond,Error)->Void	{	get	}
	init(codecMeta:CodecType,onFrameDecoded: @escaping (OutputFrameType) -> Void,onDecodeError:@escaping(Millisecond,Error)->Void) throws
	
	//	to save re-decoding, filter out the samples we dont need to re-decode from the current state
	func FilterUnneccesaryDecodes(samples:[InputFrameMeta]) -> [InputFrameMeta]
	func DecodeFrame(meta:Mp4Sample,data:Data) throws
}	
