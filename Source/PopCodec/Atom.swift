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
	//	return false to stop
	func EnumerateAtoms(fourcc:Fourcc,onAtom:@escaping(any Atom)->Bool) -> Bool
	{
		for element in self
		{
			if element.fourcc == fourcc
			{
				let continueEnum = onAtom(element)
				if !continueEnum
				{
					return false
				}
			}

			guard let children = element.childAtoms else
			{
				continue
			}
			let continueEnum = children.EnumerateAtoms(fourcc: fourcc, onAtom: onAtom)
			if !continueEnum
			{
				return false
			}
		}
		return true
	}
	
	func EnumerateAtomsOf<AtomType:Atom>() -> [AtomType]
	{
		var matches : [AtomType] = []
		
		for element in self
		{
			if let matchAtom = element as? AtomType
			{
				matches.append(matchAtom)
			}
			
			guard let children = element.childAtoms else
			{
				continue
			}
			
			let moreMatches : [AtomType] = children.EnumerateAtomsOf()
			matches.append(contentsOf: moreMatches)
		}
		return matches
	}
	
	//	recursive search
	func GetFirstChildAtom(fourcc:Fourcc) throws -> any Atom
	{
		try GetFirstChildAtom
		{
			atom in
			return atom.fourcc == fourcc
		}
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
	
	//	recursive
	func GetFirstChildAtom(where matchFunctor:(any Atom)->Bool) throws -> any Atom
	{
		for element in self
		{
			if matchFunctor(element)
			{
				return element
			}
			guard let children = element.childAtoms else
			{
				continue
			}
			if let match = try? children.GetFirstChildAtom(where: matchFunctor)
			{
				return match
			}
		}
		throw DataNotFound("No child atom matched functor")
	}
}

public struct Fourcc : CustomStringConvertible, Equatable
{
	var u32 : UInt32
	public var description : String
	{
		let isAllAscii = u32.bytes.allSatisfy{ $0.char.isASCII }
		if isAllAscii
		{
			return u32.bytes.map{ "\($0.char)" }.joined()
		}
		else
		{
			return "0x" + u32.bytes.map{ "\($0.hex)" }.joined()
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

public typealias AtomUid = UInt64	//	using file position at the moment, which may be unique enough!

//	structure for mp4, but currently used as data tree for any file
public protocol Atom : Identifiable
{
	var id : AtomUid			{get}
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

public extension Atom
{
	var id : AtomUid					{	filePosition	}	//	should be unique
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
			try await content.SkipBytes(contentSize)
			return []
		}
		
		//	pop out contents into a reader
		print("\(fourcc) reading x\(contentSize)")
		if contentSize > Int.max
		{
			throw BadDataError("Skipping decoding contents of \(fourcc) as invalid content size")
		}
		
		let childAtoms = try await content.ReadBytes(contentSize)
		{
			contentBytes in 
			var contentReader = DataReader(data: contentBytes, globalStartPosition: contentFilePosition)
			return try await AutoDecodeChildAtoms(content: &contentReader)
		}
		return childAtoms
	}
	
	func FindAtomInChildren(atomUid:AtomUid) -> (any Atom)?
	{
		guard let children = self.childAtoms else
		{
			return nil
		}
		
		for child in children
		{
			if child.id == atomUid
			{
				return child
			}
			if let childMatch = child.FindAtomInChildren(atomUid: atomUid)
			{
				return childMatch
			}
		}
		
		return nil
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

public struct ErrorAtom : Atom
{
	public var fourcc: Fourcc
	public var filePosition: UInt64
	public var headerSize: UInt64		{	representingAtom?.headerSize ?? 0	}
	public var contentSize: UInt64		{	representingAtom?.contentSize ?? 0	}
	public var totalSize: UInt64		{	representingAtom?.totalSize ?? 0	}
	public var childAtoms: [any Atom]?
	{
		representingAtom.map{ [$0] }
	}
	
	public var label : String	{	"\(errorContext): \(error.localizedDescription)"	}
	public var icon : String	{	"exclamationmark.triangle.fill"	}
	
	public var error : Error
	var errorContext : String
	var representingAtom : (any Atom)?
	
	//	this is for when the error is attached/child of a parent
	init(errorContext:String,error:Error,parent:any Atom,uidOffset:UInt64=1)
	{
		self.error = error
		self.errorContext = errorContext
		self.fourcc = Fourcc("Err!")
		self.filePosition = parent.filePosition + uidOffset	//	used as uid, so uniquify it, slightly.
	}

	//	this is an error representing the atom that has failed
	init(errorContext:String,error:Error,erroredAtom:any Atom)
	{
		self.error = error
		self.errorContext = errorContext
		self.fourcc = Fourcc("Err!")
		self.representingAtom = erroredAtom
		self.filePosition = erroredAtom.filePosition
	}
}

public struct InfoAtom : Atom
{
	public var fourcc: Fourcc
	public var filePosition: UInt64
	public var headerSize: UInt64	{	0	}
	public var contentSize: UInt64	{	totalSize	}
	public var totalSize: UInt64
	public var childAtoms: [any Atom]? = nil
	
	public var label : String	{	info	}
	static var defaultIcon : String	{	"info.circle"	}
	public var icon : String
	
	public var info : String
	static let InfoFourcc = Fourcc("Info")
	
	init(info:String,icon:String=defaultIcon,parent:any Atom,uidOffset:Int)
	{
		self.info = info
		self.icon = icon
		self.fourcc = Self.InfoFourcc
		self.filePosition = parent.filePosition + UInt64(uidOffset+1)	//	used as uid, so uniquify it, slightly.
		self.totalSize = 0
	}
	
	//	allow pos + content size to let this atom point at some place in the file
	init(info:String,icon:String=defaultIcon,filePosition:UInt64,totalSize:UInt64)
	{
		self.info = info
		self.icon = icon
		self.fourcc = Self.InfoFourcc
		self.filePosition = filePosition
		self.totalSize = totalSize
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

	//	non mp4 atom init with a single size
	init(fourcc: Fourcc, filePosition: UInt64,size:UInt64) throws
	{
		try self.init(fourcc: fourcc, filePosition: filePosition, size: 1, size64: size)
	}
	
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

