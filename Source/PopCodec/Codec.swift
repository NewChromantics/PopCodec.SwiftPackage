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
