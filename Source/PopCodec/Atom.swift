import SwiftUI


extension UInt8 
{
	var char: Character 
	{
		return Character(UnicodeScalar(self))
	}
	
	var niceChar : String
	{
		let char = self.char
		if char.isASCII
		{
			return "\(char)"
		}
		return "0x\(hex)"
	}
	
	//	hex (no 0x prefix)
	var hex : String
	{
		let a = String(self >> 4, radix: 16)
		let b = String(self & 0x0f, radix: 16)
		return a+b
	}
}


extension Array where Element == (any Atom)
{
	//	recursive search
	func GetFirstChildAtom(fourcc:Fourcc) throws -> any Atom
	{
		for element in self
		{
			if element.fourcc == fourcc
			{
				return element
			}
			guard let children = element.childAtoms else
			{
				continue
			}
			if let match = try? children.GetFirstChildAtom(fourcc: fourcc)
			{
				return match
			}
		}
		throw DataNotFound("No child atom \(fourcc)")
	}
	
	func GetFirstChildAtomAs<ExpectedType:Atom>(fourcc:Fourcc) throws -> ExpectedType
	{
		let match = try GetFirstChildAtom(fourcc: fourcc)
		guard let typed = match as? ExpectedType else
		{
			throw DataNotFound("Found child atom \(fourcc) but wrong type")
		}
		return typed
	}
	
}

public struct Fourcc : CustomStringConvertible, Equatable
{
	var u32 : UInt32
	public var description : String
	{
		return u32.bytes.reduce(into: "")
		{
			out,byte in
			out.append( byte.niceChar )
		}
	}
	
	init(_ u32: UInt32)
	{
		self.u32 = u32
	}
	
	init(_ fourcc:String)
	{
		var fourccBytes = fourcc.compactMap{ Character(extendedGraphemeClusterLiteral: $0).asciiValue }
		fourccBytes += [0,0,0,0]
		self.u32 = UInt32(fourccBytes[3],fourccBytes[2],fourccBytes[1],fourccBytes[0])
	}
}

//	structure for mp4, but currently used as data tree for any file
public protocol Atom : Identifiable
{
	var id : UInt64				{get}
	var fourcc : Fourcc			{get}
	var filePosition : UInt64	{get}
	var headerSize : UInt64		{get}
	var contentSize : UInt64	{get}
	var totalSize : UInt64		{get}
	
	//	may want non-atoms too to display arbritary calculated meta
	var childAtoms : [any Atom]?	{get}
	
	//	for ui
	var label : String	{get}
	var icon : String	{get}
}

extension Atom
{
	var id : UInt64						{	filePosition	}	//	should be unique
	var totalSize : UInt64				{	contentSize + headerSize	}
	var contentFilePosition : UInt64	{	filePosition + headerSize	}
	var totalSizeLabel : String			{	"\(totalSize) bytes"	}
	
	//	defaults
	var label : String	{self.fourcc.description}
	var icon : String	{"atom"}
	
	//	we will skip trying to decode these atoms
	func IsHeaderAtom() -> Bool
	{
		switch self.fourcc.description
		{
			case "mdat":	return false
			default:		return true
		}
	}
	
	func DecodeChildAtoms(content:inout ByteReader) async throws -> [any Atom]
	{
		if !IsHeaderAtom()
		{
			print("skipping non header atom \(fourcc) x\(contentSize)")
			try await content.SkipBytes(Int(contentSize))
			return []
		}
		
		//	pop out contents into a reader
		print("\(fourcc) reading x\(contentSize)")
		if contentSize > Int.max
		{
			throw BadDataError("Skipping decoding contents of \(fourcc) as invalid content size")
		}
		
		let contentBytes = try await content.ReadBytes(Int(contentSize))
		var contentReader = DataReader(data: contentBytes, globalStartPosition: Int(contentFilePosition))
		
		return try await AutoDecodeChildAtoms(content: &contentReader)
	}
}

extension Atom
{
	func AutoDecodeChildAtoms(content:inout DataReader) async throws -> [any Atom]
	{
		do
		{
			var children : [any Atom] = []
			try await ReadMp4Header(reader: &content)
			{
				childAtom in
				children.append(childAtom)
			}
			return children
		}
		catch
		{
			let errorAtom = ErrorAtom(errorContext:"\(self.fourcc) failed to auto decode child atoms",error:error,parent:self)
			return [errorAtom]
		}
	}
}

struct ErrorAtom : Atom
{
	var fourcc: Fourcc
	var filePosition: UInt64
	var headerSize: UInt64	{	0	}
	var contentSize: UInt64	{	0	}
	var totalSize: UInt64	{	0	}
	var childAtoms: [any Atom]? = nil
	
	var label : String	{	"\(errorContext): \(error.localizedDescription)"	}
	var icon : String	{	"exclamationmark.triangle.fill"	}
	
	var error : Error
	var errorContext : String
	
	init(errorContext:String,error:Error,parent:any Atom)
	{
		self.error = error
		self.errorContext = errorContext
		self.fourcc = Fourcc("Err!")
		self.filePosition = parent.filePosition + 1	//	used as uid, so uniquify it, slightly.
	}
}

struct InfoAtom : Atom
{
	var fourcc: Fourcc
	var filePosition: UInt64
	var headerSize: UInt64	{	0	}
	var contentSize: UInt64	{	0	}
	var totalSize: UInt64	{	0	}
	var childAtoms: [any Atom]? = nil
	
	var label : String	{	info	}
	var icon : String	{	"info.circle"	}
	
	var info : String
	
	init(info:String,parent:any Atom,uidOffset:Int)
	{
		self.info = info
		self.fourcc = Fourcc("Info")
		self.filePosition = parent.filePosition + UInt64(uidOffset+1)	//	used as uid, so uniquify it, slightly.
	}
}

struct AtomHeader : Atom
{
	var fourcc : Fourcc
	var filePosition : UInt64
	
	//	fourcc + size + size64
	var headerSize: UInt64		{	4 + 4 + (size64 != nil ? 8 : 0)	}
	var contentSize: UInt64		{	totalSize - headerSize	}
	var totalSize: UInt64		{	size64 ?? UInt64(size)	}
	
	//	total size
	var size : UInt32
	var size64 : UInt64?
	
	var childAtoms : [any Atom]? = nil
	
	init(fourcc: Fourcc, filePosition: UInt64,size:UInt32,size64:UInt64?) throws
	{
		self.fourcc = fourcc
		self.filePosition = filePosition
		self.size = size
		self.size64 = size64
		
		if size == 1 && size64 == nil
		{
			throw BadDataError("If 32bit size is 1, 64bit size(null) expected")
		}
		if size != 1 && size64 != nil
		{
			throw BadDataError("If 64bit size, 32bit size is expected to be 1(not \(size))")
		}
		
		//	if the whole atom (including header) is smaller than the min header, then something is wrong
		if totalSize < 8
		{
			let size64String = size64.map{ "\($0)" } ?? "null"
			throw BadDataError("Atom (\(fourcc)) has bad size \(totalSize) (\(size) + \(size64String))")
		}
	}
}
