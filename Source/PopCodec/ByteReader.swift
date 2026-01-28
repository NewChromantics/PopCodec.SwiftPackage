import Foundation


public protocol ByteReader
{
	var globalPosition : UInt64	{get}
	var bytesRemaining : UInt64	{get}
	
	mutating func SkipBytes(_ byteCount:UInt64) async throws
	mutating func PeekBytes(filePosition:UInt64,byteCount:UInt64) async throws -> Data
	func CheckCanRead(byteCount:UInt64) throws	//	non async, fast bounds check 
	
	@available(*, deprecated, message: "Use the ReadBytes() with lock callback")
	mutating func ReadBytes(_ byteCount:UInt64) async throws -> Data
	//	to try and help access errors, maybe this will work in the future with some explicit locks
	mutating func ReadBytes<RETURN>(_ byteCount:UInt64,onLock:(Data)async throws->RETURN) async throws -> RETURN
	
	mutating func ReadBytes<TYPE>(to buffer:inout TYPE,reverse:Bool) async throws
	mutating func ReadBytes<TYPE>(to buffer:inout Array<TYPE>) async throws
	
	//	get a reader for the this next amount of bytes, (and skip it)
	mutating func GetReaderForBytes(byteCount:UInt64) async throws -> ByteReader
}

extension ByteReader
{
	public func CheckCanRead(byteCount:UInt64) throws
	{
		if byteCount == 0
		{
			return
		}
		
		//	we're sat at the end of the file, reads will fail
		if bytesRemaining == 0
		{
			throw EndOfDataError()
		}
		
		if byteCount > bytesRemaining
		{
			throw BadDataError("Reading beyond end of data")
		}
	}
	
	//	default implementation
	//	gr: this is only for raw types, not arrays
	mutating public func ReadBytes<TYPE>(to buffer:inout TYPE,reverse:Bool=false) async throws
	{
		let byteCount = {
			return withUnsafeMutableBytes(of: &buffer)
			{
				return $0.count
			}
		}()
		
		try await self.ReadBytes(UInt64(byteCount))
		{
			data in
			withUnsafeMutableBytes(of: &buffer)
			{
				buffer in
				if !reverse
				{
					data.copyBytes(to: buffer)
				}
				else
				{
					for (index,byte) in data.enumerated()
					{
						let writeIndex = reverse ? (buffer.count-1-index) : index
						buffer[writeIndex] = byte
					}
				}
			}
		}
	}
	
	mutating public func ReadBytes<TYPE>(to buffer:inout Array<TYPE>) async throws
	{
		let byteCount = buffer.withUnsafeMutableBufferPointer
		{
			bufferBuffer in
			bufferBuffer.count * MemoryLayout<TYPE>.size
		}
		try await self.ReadBytes(UInt64(byteCount))
		{
			data in
			buffer.withUnsafeMutableBufferPointer
			{
				bufferBuffer in
				data.copyBytes(to: bufferBuffer)
			}
		}
	}
	
	mutating public func ReadAs<TYPE>() async throws -> TYPE
	{
		let byteCount = MemoryLayout<TYPE>.stride
		let instance = try await ReadBytes(UInt64(byteCount))
		{
			data in
			let instance = data.withUnsafeBytes
			{
				return $0.load(as: TYPE.self)
			}
			return instance
		}
		return instance
	}
	
	mutating func ReadAtom() async throws -> any Atom
	{
		//	read header, length etc
		let atomStartFilePosition = self.globalPosition
		let size = try await Read32()
		let fourcc = try await ReadFourcc()
		
		//	size of 1 means 64 bit size
		var size64 : UInt64? = nil
		if size == 1
		{
			size64 = try await Read64()
		}
		
		var atom = try AtomHeader(fourcc: fourcc, filePosition: atomStartFilePosition, size:size, size64:size64)
		//	get calculated size
		let atomSize = atom.totalSize
		
		//	if the whole atom (including header) is smaller than the min header, then something is wrong
		if atomSize < 8
		{
			throw BadDataError("Atom (\(fourcc)) has bad size \(atomSize)")
		}
		
		var selfReader = self as (any ByteReader)
		
		do
		{
			//	see if we convert to a specific atom type
			if let specalisedAtom = try await Mp4AtomFactory.AllocateAtom(header: atom, content: &selfReader)
			{
				print("got specialised atom \(specalisedAtom.fourcc)")
				return specalisedAtom
			}
		}
		catch
		{
			return ErrorAtom(errorContext: "Error Decoding \(atom.fourcc)", error: error, erroredAtom: atom)
		}
		
		//	generic atom, see if we can auto decode child atoms
		let childAtoms = try await atom.DecodeChildAtoms(content:&selfReader)
		if !childAtoms.isEmpty
		{
			atom.childAtoms = childAtoms
		}
		
		return atom
	}
	
	mutating func ReadFourcc() async throws -> Fourcc
	{
		let u32 = try await Read32Reversed()
		return Fourcc(u32)
	}
	
	mutating func Read64() async throws -> UInt64
	{
		var value : UInt64 = 0
		try await ReadBytes(to: &value,reverse:true)
		return value
	}
	
	mutating func Read32() async throws -> UInt32
	{
		var value : UInt32 = 0
		try await ReadBytes(to: &value,reverse:true)
		return value
	}
	
	mutating func Read32Reversed() async throws -> UInt32
	{
		var value : UInt32 = 0
		try await ReadBytes(to: &value,reverse:false)
		return value
	}
	
	mutating func Read16() async throws -> UInt16
	{
		var value : UInt16 = 0
		try await ReadBytes(to: &value,reverse:true)
		return value
	}
	
	mutating func Read8() async throws -> UInt8
	{
		return try await ReadBytes(1)
		{
			return $0[0]
		}
	}
	
	mutating func Read24() async throws -> UInt32
	{
		return try await ReadBytes(3)
		{
			bytes in
			let u24 = UInt32(bytes[0], bytes[1], bytes[2], 0)
			return u24
		}
	}
	
}

public class DataReader : ByteReader
{
	var position : UInt64
	var globalStartPosition : UInt64	//	when reading nested data, this is the external offset
	var data : Data
	private var overrideDataLength : UInt64? 	//	to avoid slicing, manually dictate the end  
	public var globalPosition : UInt64	{	UInt64(position + globalStartPosition)	}
	var dataCount : UInt64				{	overrideDataLength ?? UInt64(data.count)	}
	public var bytesRemaining: UInt64	{	dataCount - position	}
	
	public init(data: Data,position:UInt64=0,overrideDataLength:UInt64?=nil,globalStartPosition:UInt64=0) 
	{
		self.globalStartPosition = globalStartPosition
		self.position = position
		self.data = data
		self.overrideDataLength = overrideDataLength
		//	bad override provided! init is no throw atm though
		if let overrideDataLength, overrideDataLength > data.count
		{
			self.overrideDataLength = UInt64(data.count)
		}
	}
	
	//	get a reader for the this next amount of bytes, (and skip it)
	public func GetReaderForBytes(byteCount:UInt64) async throws -> any ByteReader
	{
		//	check there's enough data left
		try CheckCanRead(byteCount:byteCount)
		
		//	it seems that making a data subscript/slice of another data which doesnt start at zero... crashes
		//	starting at 0 with an offset, doesnt crash
		//let contentData = data[offset..<offset+Int(size)]
		//var content = DataReader(data: contentData,position: 0,globalStartPosition:0)
		let sliceSize = UInt64(self.position) + byteCount
		
		//	avoiding slice...
		//let contentData = data[0..<sliceSize]
		//var content = DataReader(data: contentData,position: position,globalStartPosition:self.globalStartPosition)
		let contentData = data
		var content = DataReader(data: contentData,position: position, overrideDataLength:sliceSize,globalStartPosition:self.globalStartPosition)
		
		
		//	now skip over it as we've "read" it into this other reader
		try await self.SkipBytes(byteCount)
		return content
	}

	public func PeekBytes(filePosition: UInt64, byteCount: UInt64) async throws -> Data 
	{
		let read = data[filePosition..<filePosition+byteCount]
		return read
	}
	
	//	fast case
	public func Read8() async throws -> UInt8
	{
		try CheckCanRead(byteCount: 1)
		let byte = data[Int(position)]
		position += 1
		return byte
	}
	
	public func ReadBytes<RETURN>(_ byteCount: UInt64, onLock: (Data) async throws -> RETURN) async throws -> RETURN
	{
		//	should this error?
		if byteCount == 0
		{
			return try await onLock(Data())
		}
		
		//	we're sat at the end of the file, reads will fail
		if position == dataCount
		{
			throw EndOfDataError()
		}
		
		if position + byteCount > dataCount
		{
			throw BadDataError("Reading beyond end of data")
		}
		
		//	something about reading data[] of data[] is going wrong, so forcing an allocation...
		//	gr: there's something bad about data[data[xxx]] when the inner data isn't starting at zero
		//		but even doing Array(slide) on a single byte is crashing with a read error
		//let slice = data[position..<position+byteCount]
		//	is this more reliable???
		//	todo: try using unsafemutable buffers which has a very explicit lock/lifetime
		//			but dont know how to get a reliable offset
		
		//	gr: reading bytes directly doesnt actually seem to be that slow, would be nice to do a chunk
		//		but this isnt crashing...
		//		nope! still crashes!
		var slice : [UInt8] = []
		slice.reserveCapacity(Int(byteCount))
		for i in position..<position+byteCount
		{
			slice.append(data[Data.Index(i)])
		}
		//let slice = data.subdata(in: Data.Index(position)..<Data.Index(position+byteCount))
		//let slice = data[position..<position+byteCount]	//	crashing on byte1!
		//let read = data[position..<position+byteCount]
		//let read = Array(slice)
		if slice.count != byteCount
		{
			fatalError("Got wrong number of bytes(\(slice.count)) for requested \(byteCount)")
		}
		//let result = try await onLock(slice)
		let result = try await onLock( Data(slice) )
		
		//	move along only on success
		//	gr: is there any code that then expects our pointer to have moved?
		//		current setup means .position == data's start in onlock()
		position += byteCount
		
		return result
	}
	
	
	//	deprecated, remove this
	public func ReadBytes(_ byteCount: UInt64) async throws -> Data 
	{
		//	should this error?
		if byteCount == 0
		{
			return Data()
		}
		
		try CheckCanRead(byteCount:byteCount)
		
		//	something about reading data[] of data[] is going wrong, so forcing an allocation...
		let slice = data[position..<position+byteCount]
		//let read = data[position..<position+byteCount]
		let read = Array(slice)
		if read.count != byteCount
		{
			fatalError("Got wrong number of bytes(\(read.count)) for requested \(byteCount)")
		}
		position += byteCount
		return Data(read)
	}
	
	public func SkipBytes(_ byteCount:UInt64) async throws 
	{
		let newPosition = position + byteCount
		//	walking to the end is okay (hit EOF) - fail when reading AFTER the data
		//	walking past, is bad
		if newPosition > dataCount
		{
			throw BadDataError("Skipping past EOF; new position \(newPosition)/\(dataCount)")
		}
		self.position = newPosition
	}
}

extension UInt32
{
	init(_ a:UInt8,_ b:UInt8,_ c:UInt8,_ d:UInt8)
	{
		var u32 : UInt32 = 0
		u32 |= UInt32(a) << 24
		u32 |= UInt32(b) << 16
		u32 |= UInt32(c) << 8
		u32 |= UInt32(d) << 0
		self.init(u32)
	}
	
	var bytes : [UInt8]
	{
		var theBytes : [UInt8] = []
		withUnsafeBytes(of:self)
		{
			theBytes.append($0[0])
			theBytes.append($0[1])
			theBytes.append($0[2])
			theBytes.append($0[3])
		}
		return theBytes
	}
}

