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


struct HevcPacket
{
	var filePosition : UInt64
	var type : UInt8
	var naluCount : UInt16
	var totalSize : UInt64		{	1 + 2 + naluTotalDataSize	}

	var nalus : [HevcNalu]
	var naluTotalDataSize : UInt64	{	nalus.map{ $0.totalSize }.reduce(0, {total,this in total + this })	}
}

struct HevcNalu
{
	var data : [UInt8]
	var filePosition : UInt64
	var totalSize : UInt64	{	UInt64(data.count)	}
}

//	h265
public struct HevcCodec : Codec
{
	public static var name: String = "HEVC"
	
	var parameterSets : [[UInt8]]
	var packets : [HevcPacket]
	
	func GetMetaAtoms(parent:any Atom) -> [any Atom]
	{
		return packets.flatMap
		{
			packet in
			let packetMeta = InfoAtom(info: "Packet \(packet.type)", filePosition: packet.filePosition, totalSize: packet.totalSize)
			let naluMetas = packet.nalus.map
			{
				nalu in
				return InfoAtom(info: "Nalu", filePosition: nalu.filePosition, totalSize: nalu.totalSize)
			}
			return [packetMeta] + naluMetas
		}
	}
	
	public func GetFormat() throws -> CMVideoFormatDescription
	{
		let hps = parameterSets.map{ Data($0) }
		do
		{
			//	this crashes if data length is zero
			for ps in hps
			{
				if ps.isEmpty
				{
					throw PopCodecError("Zero sized parameter set passed to CoreVideo format will crash")
				}
			}
			
			let format = try CMFormatDescription(hevcParameterSets: hps)
			return format
		}
		catch
		{
			throw PopCodecError("Failed to allocate hevc format; \(error)")
		}
	}
}

public struct H264Codec : Codec
{
	public static var name: String = "H264"

	var profile : UInt8 = 0
	var compatibility : UInt8 = 0
	var level : UInt8 = 0
	var sps : [[UInt8]] = []
	var pps : [[UInt8]] = []
	
	var lengthMinusOne : UInt8 = 0
	var naluPrefixSize : Int	{	Int(lengthMinusOne) + 1	}
	
	func GetMetaAtoms(parent:any Atom) -> [any Atom]
	{
		return [
			InfoAtom(info:"profile \(profile)",parent: parent,uidOffset: 2),
			InfoAtom(info:"compatibility \(compatibility)",parent: parent,uidOffset: 3),
			InfoAtom(info:"level \(level)",parent: parent,uidOffset: 4),
			InfoAtom(info:"sps x\(sps.count)",parent: parent,uidOffset: 5),
			InfoAtom(info:"pps x\(pps.count)",parent: parent,uidOffset: 6),
		]
	}
	
	public func GetFormat() throws -> CMVideoFormatDescription
	{
		let parameterSets = [
			Data(self.sps.first!),
			Data(self.pps.first!)
		]
		
		//	-12712 http://stackoverflow.com/questions/25078364/cmvideoformatdescriptioncreatefromh264parametersets-issues
		//let format = try CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: <#T##Int#>, parameterSetPointers: <#T##UnsafePointer<UnsafePointer<UInt8>>#>, parameterSetSizes: <#T##UnsafePointer<Int>#>, nalUnitHeaderLength: <#T##Int32#>, formatDescriptionOut: <#T##UnsafeMutablePointer<CMFormatDescription?>#>)
		//CMVideoFormatDescriptionCreateFromH264ParameterSets
		let format = try CMFormatDescription(h264ParameterSets: parameterSets, nalUnitHeaderLength: self.naluPrefixSize)
		return format
	}
}

