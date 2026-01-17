import CoreMedia


public protocol Codec
{
	static var name : String	{get}
	var name : String	{get}
	
	//	may want to specialise this in a videotoolbox codec
	func GetFormat() throws -> CMVideoFormatDescription
}

public extension Codec
{
	var name : String	{	Self.name	}
}

struct MissingCodec : Codec
{
	static var name: String	{	"Missing Codec"	}
	
	func GetFormat() throws -> CMVideoFormatDescription 
	{
		throw PopCodecError("Missing codec couldnt make CMVideoFormatDescription")
	}
	
}
