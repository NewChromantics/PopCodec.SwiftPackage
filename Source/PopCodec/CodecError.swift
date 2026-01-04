import SwiftUI


internal struct PopCodecError : LocalizedError
{
	let description: String
	
	public init(_ description: String) {
		self.description = description
	}
	
	public var errorDescription: String? {
		description
	}
}



internal struct EndOfDataError : LocalizedError
{
	public init() 
	{
	}
	
	public var errorDescription: String? {
		"EndOfData"
	}
}

internal struct BadDataError : LocalizedError
{
	var description : String 
	
	public init(_ description:String) 
	{
		self.description = description
	}
	
	public var errorDescription: String? {
		"BadData: \(description)"
	}
}

public struct DataNotFound : LocalizedError
{
	let description: String
	
	public init(_ description: String) {
		self.description = description
	}
	
	public var errorDescription: String? {
		description
	}
}

