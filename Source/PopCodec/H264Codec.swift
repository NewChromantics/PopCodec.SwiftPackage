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


//	sequence/packet/parameterset
struct HevcParameter
{
	var filePosition : UInt64
	var parameterHeader : UInt8

	var arrayCompleteness : UInt8	{	(parameterHeader>>7) & 0x1	}
	var reservedZero : UInt8		{ 	(parameterHeader>>6) & 0x1	}
	var contentTypeValue : UInt8		{	(parameterHeader>>0) & 0x3f	}
	var contentType : HevcNaluContentType?	{	HevcNaluContentType(rawValue: contentTypeValue)	}
	var contentTypeLabel : String			{	contentType.map{ "\($0)" } ?? "ContentType(\(contentTypeValue)"	}
	
	var naluCount : UInt16
	var totalSize : UInt64		
	{
		1 + //	parameter header
		2 +	//	nalu count 
		naluTotalDataSize	
	}
	var nalus : [HevcNalu]
	var naluTotalDataSize : UInt64	{	nalus.map{ $0.totalSize }.reduce(0, {total,this in total + this })	}
	
	var dataWithoutLengthPrefix : [UInt8]	
	{
		//[parameterHeader] +
		//naluCount.bytes + 
		nalus.flatMap{$0.dataWithoutLengthPrefix}
		//nalus.flatMap{$0.totalData}
	}
	
	static func StripEmulationPrevention(_ data:[UInt8]) -> [UInt8]
	{
		//	https://stackoverflow.com/a/24890903/355753
		//	this is when some perfectly valid data contains 0 0 0
		//	so to prevent this being detected as 001 or 0001 emulation
		//	prevention is inserted to turn it into 003 or 0030
		var strippedData = data
		for i in 0..<data.count-2
		{
			let a = data[i+0]
			let b = data[i+1]
			let c = data[i+2]
			if a == 0 && b == 0 && c == 3
			{
				strippedData[i+2] = 0
			}
		}
		return strippedData
	}
}

enum HevcNaluContentType : UInt8	//	6bit
{
	//	https://datatracker.ietf.org/doc/html/draft-schierl-payload-rtp-h265-01
	//	https://github.com/nokiatech/vpcc/blob/master/Sources/HEVC.h
	case 
	CODED_SLICE_TRAIL_N = 0,
	CODED_SLICE_TRAIL_R = 1,
	
	CODED_SLICE_TSA_N = 2,
	CODED_SLICE_TSA_R = 3,
	
	CODED_SLICE_STSA_N = 4,
	CODED_SLICE_STSA_R = 5,
	
	CODED_SLICE_RADL_N = 6,
	CODED_SLICE_RADL_R = 7,
	
	CODED_SLICE_RASL_N = 8,
	CODED_SLICE_RASL_R = 9,
	
	RESERVED_VCL_N10 = 10,
	RESERVED_VCL_R11 = 11,
	RESERVED_VCL_N12 = 12,
	RESERVED_VCL_R13 = 13,
	RESERVED_VCL_N14 = 14,
	RESERVED_VCL_R15 = 15,
	
	CODED_SLICE_BLA_W_LP = 16,
	CODED_SLICE_BLA_W_RADL = 17,
	CODED_SLICE_BLA_N_LP = 18,
	CODED_SLICE_IDR_W_RADL = 19,
	CODED_SLICE_IDR_N_LP = 20,
	CODED_SLICE_CRA = 21,
	
	RESERVED_IRAP_VCL22 = 22,
	RESERVED_IRAP_VCL23 = 23,
	
	RESERVED_VCL24 = 24,
	RESERVED_VCL25 = 25,
	RESERVED_VCL26 = 26,
	RESERVED_VCL27 = 27,
	RESERVED_VCL28 = 28,
	RESERVED_VCL29 = 29,
	RESERVED_VCL30 = 30,
	RESERVED_VCL31 = 31,
	
	VPS = 32,
	SPS = 33,
	PPS = 34,
	ACCESS_UNIT_DELIMITER = 35,
	EOS = 36,
	EOB = 37,
	FILLER_DATA = 38,
	PREFIX_SEI = 39,
	SUFFIX_SEI = 40,
	
	RESERVED_NVCL41 = 41,
	RESERVED_NVCL42 = 42,
	RESERVED_NVCL43 = 43,
	RESERVED_NVCL44 = 44,
	RESERVED_NVCL45 = 45,
	RESERVED_NVCL46 = 46,
	RESERVED_NVCL47 = 47,
	
	UNSPECIFIED_48 = 48,
	UNSPECIFIED_49 = 49,
	UNSPECIFIED_50 = 50,
	UNSPECIFIED_51 = 51,
	UNSPECIFIED_52 = 52,
	UNSPECIFIED_53 = 53,
	UNSPECIFIED_54 = 54,
	UNSPECIFIED_55 = 55,
	UNSPECIFIED_56 = 56,
	UNSPECIFIED_57 = 57,
	UNSPECIFIED_58 = 58,
	UNSPECIFIED_59 = 59,
	UNSPECIFIED_60 = 60,
	UNSPECIFIED_61 = 61,
	UNSPECIFIED_62 = 62,
	UNSPECIFIED_63 = 63,
	
	INVALID = 64
}

extension UInt16
{
	var bytes : [UInt8]	{	[UInt8( (self << 0) & 0xff), UInt8( (self << 8) & 0xff )]	}
}

struct HevcNalu
{
	var contentSize : UInt16
	var dataWithoutLengthPrefix : [UInt8]			//	doesn't include .contentSize
	var totalData :	[UInt8]		{	contentSize.bytes + dataWithoutLengthPrefix	}
	var filePosition : UInt64
	var totalSize : UInt64	{	UInt64(totalData.count)	}
	/*
	var contentType : HevcNaluContentType?	{	HevcNaluContentType(rawValue:UInt8(contentTypeValue))	}
	var contentTypeLabel : String	{	contentType.map{ "\($0)" } ?? "ContentType(\(contentTypeValue)"	}
	
	var header16 : UInt16			{	UInt16(dataWithoutLengthPrefix[0] << 0) | UInt16(dataWithoutLengthPrefix[1] << 8)	}
	var forbiddenZero : UInt16		{	(header16 << 0) & (1)	}		//	0 bit
	var contentTypeValue : UInt16	{	(header16 << 1) & (0x3f)	}	//	1-6 bits
	var layer : UInt16				{	(header16 << 7) & (0x3f)	}	//	7-14 bits
	var temporalIdPlusOne : UInt16	{	(header16 << 13) & (0x3)	}	//	13-15 bits
	var temporalId : Int			{	Int(temporalIdPlusOne) + 1	}*/
	
}

//	h265
public struct HevcCodec : Codec
{
	public static var name: String = "HEVC"
	
	var parameters : [HevcParameter]
	var naluHeaderSize : UInt8
	
	func GetMetaAtoms(parent:any Atom) -> [any Atom]
	{
		return parameters.flatMap
		{
			parameter in
			let packetMeta = InfoAtom(info: "Parameter \(parameter.contentTypeLabel)", filePosition: parameter.filePosition, totalSize: parameter.totalSize)
			let naluMetas = parameter.nalus.map
			{
				nalu in
				//return InfoAtom(info: "Nalu \(nalu.contentTypeLabel) zero=\(nalu.forbiddenZero) layer=\(nalu.layer) temporalId=\(nalu.temporalId)", filePosition: nalu.filePosition, totalSize: nalu.totalSize)
				return InfoAtom(info: "Nalu", filePosition: nalu.filePosition, totalSize: nalu.totalSize)
			}
			return [packetMeta] + naluMetas
		}
	}
	
	func GetPacket(_ contentType:HevcNaluContentType) throws -> HevcParameter
	{
		let match = parameters.first{ $0.contentType == contentType }
		guard let match else
		{
			throw DataNotFound("No \(contentType)")
		}
		return match
	}
	
	public func GetFormat() throws -> CMVideoFormatDescription
	{
		do
		{
			//	from Avf::GetFormatDescriptionHevc
			//	apple docs: (header)
			//	The parameter sets' data can come from raw NAL units and must have any emulation prevention bytes needed.
			//	The supported NAL unit types to be included in the format description are
			//	32 (video parameter set),
			//	33 (sequence parameter set),
			//	34 (picture parameter set),
			//	39 (prefix SEI) and
			//	40 (suffix SEI). At least one of each parameter set must be provided.
			let vps = try GetPacket(HevcNaluContentType.VPS)
			let sps = try GetPacket(HevcNaluContentType.SPS)
			let pps = try GetPacket(HevcNaluContentType.PPS)
			//	these are optional
			let seiPrefix = try? GetPacket(HevcNaluContentType.PREFIX_SEI)
			let seiSuffix = try? GetPacket(HevcNaluContentType.SUFFIX_SEI)
			
			//	this should not include nalu prefix length
			//	should also strip emulation bytes
			let packets = [vps,sps,pps,seiPrefix,seiSuffix].compactMap{$0}
			var parameterSetBytes = packets.map{ $0.dataWithoutLengthPrefix }
			//parameterSetBytes = parameterSetBytes.map{ HevcParameter.StripEmulationPrevention($0)	}
			let parameterSetDatas = parameterSetBytes.map{ Data($0) }
			
			//	this crashes if data length is zero
			for ps in parameterSetDatas
			{
				if ps.isEmpty
				{
					throw PopCodecError("Zero sized parameter set passed to CoreVideo format will crash")
				}
			}

			//	https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreatefromhevcparametersets(allocator:parametersetcount:parametersetpointers:parametersetsizes:nalunitheaderlength:extensions:formatdescriptionout:)
			//	Creates a format description for a video media stream using HEVC (H.265) parameter set NAL units.
			let format = try CMFormatDescription(hevcParameterSets: parameterSetDatas, nalUnitHeaderLength: Int(self.naluHeaderSize))
			let outputParameterSets = format.parameterSets
			let dimensions = format.presentationDimensions()
			let nalUnitHeaderLength = format.nalUnitHeaderLength
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
		
		//HevcParameter.StripEmulationPrevention
		
		//	-12712 http://stackoverflow.com/questions/25078364/cmvideoformatdescriptioncreatefromh264parametersets-issues
		//let format = try CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: <#T##Int#>, parameterSetPointers: <#T##UnsafePointer<UnsafePointer<UInt8>>#>, parameterSetSizes: <#T##UnsafePointer<Int>#>, nalUnitHeaderLength: <#T##Int32#>, formatDescriptionOut: <#T##UnsafeMutablePointer<CMFormatDescription?>#>)
		//CMVideoFormatDescriptionCreateFromH264ParameterSets
		let format = try CMFormatDescription(h264ParameterSets: parameterSets, nalUnitHeaderLength: self.naluPrefixSize)
		return format
	}
}

