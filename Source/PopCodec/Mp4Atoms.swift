/*
	Specialised atom decoding
*/
//import Foundation	//	TimeInterval (double)
import Foundation
typealias Seconds = Double	//	TimeInterval, but skip dependency of Foundation

protocol SpecialisedAtom : Atom
{
	static var fourcc : Fourcc	{get}
	static func Decode(header:AtomHeader,content:inout DataReader) async throws -> Self
	
	//	just to make it simpler - copy the header that comes in
	var header : AtomHeader		{get set}
}

extension SpecialisedAtom
{
	var fourcc : Fourcc			{	header.fourcc	}
	var filePosition: UInt64	{	header.filePosition	}
	var headerSize: UInt64		{	header.headerSize	}
	var contentSize: UInt64		{	header.contentSize	}
	var totalSize: UInt64		{	header.totalSize	}
}


class Mp4AtomFactory
{
	//	return null if non-specific auto-decode atom
	static func AllocateAtom(header:AtomHeader,content:inout ByteReader) async throws -> (any Atom)?
	{
		let factoryTypes : [any SpecialisedAtom.Type] =
		[
			Atom_ftyp.self,
			Atom_stsd.self,
			Atom_hev1.self,
			Atom_hvc1.self,
			Atom_hvcc.self,
			Atom_avc1.self,
			Atom_avcc.self,
			Atom_trak.self,
			Atom_mp4a.self,
			Atom_ctts.self,
			Atom_stbl.self,
			Atom_stsz.self,
			Atom_stss.self,
			Atom_stts.self,
			Atom_stco.self,
			Atom_co64.self,
			Atom_stsc.self,
			Atom_mdhd.self,
			Atom_text.self,
		]
		
		guard let type = factoryTypes.first(where: {$0.fourcc == header.fourcc}) else
		{
			print("no specialisation for \(header.fourcc)")
			return nil
		}
		
		let contentBytes = try await content.ReadBytes(Int(header.contentSize))
		var contentReader = DataReader(data: contentBytes, globalStartPosition: Int(header.contentFilePosition))
		
		let atom = try await type.Decode(header: header, content: &contentReader)
		return atom
	}
}



struct SampleChunkMeta
{
	//	data is little endian
	var firstChunk_le : UInt32 = 0
	var samplesPerChunk_le : UInt32 = 0
	var sampleDescriptionId_le : UInt32 = 0
	
	var firstChunk : UInt32				{	firstChunk_le.byteSwapped	}
	var samplesPerChunk : UInt32		{	samplesPerChunk_le.byteSwapped	}
	var sampleDescriptionId : UInt32	{	sampleDescriptionId_le.byteSwapped	}
}


//	media meta can override movie meta (eg. timescale)
struct MediaMeta
{
	func GetMetaAtoms(parent:Atom_mdhd) -> [any Atom]
	{[
		InfoAtom(info: "Version \(version)", parent: parent, uidOffset: 0),
		InfoAtom(info: "flags \(flags)", parent: parent, uidOffset: 1),
		InfoAtom(info: "creationTime_SecondsSinceJan1st1904 \(creationTime_SecondsSinceJan1st1904)", parent: parent, uidOffset: 2),
		InfoAtom(info: "modificationTime_SecondsSinceJan1st1904 \(modificationTime_SecondsSinceJan1st1904)", parent: parent, uidOffset: 3),
		InfoAtom(info: "timeUnitsPerSecond \(timeUnitsPerSecond)", parent: parent, uidOffset: 4),
		InfoAtom(info: "duration \(durationSeconds)secs", parent: parent, uidOffset: 5),
		InfoAtom(info: "Version \(version)", parent: parent, uidOffset: 6),
		InfoAtom(info: "Version \(version)", parent: parent, uidOffset: 7),
	]}
	
	//	media can have it's own timescale
	var version : UInt8 = 0
	var flags : UInt32 = 0	//	24 bit
	var creationTime_SecondsSinceJan1st1904 : UInt32 = 0
	var modificationTime_SecondsSinceJan1st1904 : UInt32 = 0
	//Header.CreationTimeMs = GetDateTimeFromSecondsSinceMidnightJan1st1904(CreationTime);
	//Header.ModificationTimeMs = GetDateTimeFromSecondsSinceMidnightJan1st1904(ModificationTime);
	var timeUnitsPerSecond : UInt32 = 1000
	var durationTimeUnit : UInt32 = 0
	var durationSeconds : Seconds	{	self.TimeUnitToSeconds(time: durationTimeUnit)	}
	var durationMilliseconds : UInt64	{	self.TimeUnitToMilliseconds(time: durationTimeUnit)	}
	var language : UInt16 = 0
	var quality16 : UInt16 = 0
	var quality : Double	{	Double(quality16) / Double(1 << 16)	}
		
	
	
	func TimeUnitToSeconds(time:UInt32) -> Seconds
	{
		let secs = Double(time) / Double(timeUnitsPerSecond)
		return secs
	}
	
	//	less precise!
	func TimeUnitToMilliseconds(time:UInt32) -> UInt64
	{
		let secs = TimeUnitToSeconds(time: time)
		let ms = secs * 1000.0
		return UInt64(ms)
	}
}



struct Atom_ftyp : Atom, SpecialisedAtom
{
	static var fourcc : Fourcc	{	Fourcc("ftyp")	}
	
	var header: AtomHeader
	var childAtoms: [any Atom]?
	{
		[InfoAtom(info: type.description, parent: self, uidOffset: 1)]
	}
	var type : Fourcc
	
	static func Decode(header: AtomHeader, content: inout DataReader) async throws -> Atom_ftyp 
	{
		let type = try await content.ReadFourcc()
		return Atom_ftyp(header:header,type:type)
	}
}


//	sample description, contains codec
struct Atom_stsd : Atom, SpecialisedAtom
{
	static var fourcc : Fourcc	{	Fourcc("stsd")	}
	
	var header: AtomHeader
	var childAtoms : [any Atom]?	{	metaAtoms + children }
	var metaAtoms: [any Atom]
	{[
		InfoAtom(info: "Version \(version)", parent: self, uidOffset: 0),
		InfoAtom(info: "Flags \(flags)", parent: self, uidOffset: 1),
		InfoAtom(info: "Entries \(entryCount)", parent: self, uidOffset: 2)
	]}
	var children : [any Atom]
	var version : UInt8
	var flags : UInt32
	var entryCount : UInt32
	
	static func Decode(header: AtomHeader, content: inout DataReader) async throws -> Self 
	{
		//	 https://www.cimarronsystems.com/wp-content/uploads/2017/04/Elements-of-the-H.264-VideoAAC-Audio-MP4-Movie-v2_0.pdf
		let version = try await content.Read8()
		let flags = try await content.Read24()
		let entryCount = try await content.Read32()
		
		//	each entry is essentially an atom
		//	https://github.com/NewChromantics/PopCodecs/blob/master/PopMpeg4.cs#L1022
		//	should match EntryCount
		var childAtoms : [any Atom] = []
		while content.bytesRemaining > 0
		{
			let childAtom = try await content.ReadAtom()
			childAtoms.append(childAtom)
		}
		
		return Atom_stsd(header: header, children: childAtoms, version: version, flags: flags, entryCount: entryCount)
	}
}


/*
struct Atom_mdhd : Atom
{
	var fourcc: Fourcc
	var filePosition: UInt64
	var headerSize: UInt64
	var contentSize: UInt64
	var childAtoms: [any Atom]? = nil
	
	static func Read(parent:any Atom,content:inout DataReader) async throws -> Atom_mdhd
	{
		/*
		auto Version = Reader.Read8();
		auto Flags = Reader.Read24();
		auto CreationTime = Reader.Read32();
		auto ModificationTime = Reader.Read32();
		auto TimeScale = Reader.Read32();
		auto Duration = Reader.Read32();
		auto Language = Reader.Read16();
		auto Quality = Reader.Read16();
		
		MediaHeader_t Header(MovieHeader);
		Header.TimeScaleUnitsPerSecond = TimeScale;
		//Header.Duration = new TimeSpan(0,0, (int)(Duration * Header.TimeScale));
		Header.CreationTimeMs = GetDateTimeFromSecondsSinceMidnightJan1st1904(CreationTime);
		Header.ModificationTimeMs = GetDateTimeFromSecondsSinceMidnightJan1st1904(ModificationTime);
		Header.LanguageId = Language;
		Header.Quality = Quality / static_cast<float>(1 << 16);
		Header.DurationMs = Header.TimeUnitsToMs( Duration );
		 */
	}
}
*/


//	this contains some image meta, then AVCC & PASP
struct Atom_avc1 : Atom, SpecialisedAtom, VideoCodecAtom
{
	static let fourcc = Fourcc("avc1")
	
	var header : AtomHeader
	var videoCodecMeta: VideoCodecMeta
	var codec : CodecWithMetaAtoms?
	var childAtoms : [any Atom]?
	{
		codecMetaAtoms
		+
		videoCodecMeta.GetMetaAtoms(parent: self)
		+
		videoCodecMeta.childAtoms
	}
	var codecMetaAtoms : [any Atom]	{	codec?.GetMetaAtoms(parent: self) ?? []	}

		
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let videoCodecMeta = try await VideoCodecMeta(header: header, data: &content)
		
		let avcc : Atom_avcc? = try? videoCodecMeta.childAtoms.GetFirstChildAtomAs(fourcc: Atom_avcc.fourcc)
		
		return Self(header:header, videoCodecMeta:videoCodecMeta, codec: avcc?.codec)
	}
}


struct Atom_avcc : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("avcC")
	
	var header : AtomHeader 
	var version : UInt8
	var codec : H264Codec

	var childAtoms : [any Atom]?
	{
		[InfoAtom(info:"Version \(version)",parent: self,uidOffset: 0)]
		+
		codec.GetMetaAtoms(parent:self)
	}
	
	
	
	static func Decode(header: AtomHeader, content: inout DataReader) async throws -> Atom_avcc 
	{
		var h264 = H264Codec()
		let version = try await content.Read8()
		try await content.ReadBytes(to: &h264.profile) 
		try await content.ReadBytes(to: &h264.compatibility) 
		try await content.ReadBytes(to: &h264.level) 
		
		let ReservedAndSizeLength = try await content.Read8()	//	6bits==0 3==lengthminusone
		let Reserved1 =  ReservedAndSizeLength & 0b11111100;
		h264.lengthMinusOne = ReservedAndSizeLength & 0b00000011;
		
		let ReservedAndSpsCount = try await content.Read8()
		let SpsCount =  ReservedAndSpsCount & 0b00011111;
		let Reserved2 = ReservedAndSpsCount & 0b11100000;
		
		for _ in 0..<SpsCount
		{
			let SpsLength = try await content.Read16();
			let sps = try await content.ReadBytes(Int(SpsLength) )
			h264.sps.append( Array(sps) )
		}
		
		let PpsCount = try await content.Read8()
		for _ in 0..<PpsCount
		{
			let PpsLength = try await content.Read16()
			let pps = try await content.ReadBytes(Int(PpsLength) )
			h264.pps.append( Array(pps) )
		}
		
		let remaining = content.bytesRemaining
		print("avc1 content size \(remaining)")
		
		let atom = Self(header:header, version: version,codec: h264)
		return atom
	}
}


//	hev1, avc1, hvc1 atoms all have this meta, then child atoms, in their data
protocol VideoCodecAtom : Atom
{
	var codec : CodecWithMetaAtoms?	{get}	//	null if we failed to decode specialised codec meta
	var videoCodecMeta : VideoCodecMeta	{get}
}


struct VideoCodecMeta
{
	var reserved_x6 : [UInt8]
	var dataReferenceIndex : UInt16
	var predefines_x16 : [UInt8]
	
	var mediaWidth : UInt16
	var mediaHeight : UInt16
	var horzResolution : UInt16
	var horzResolutionLow : UInt16
	var vertResolution : UInt16
	var vertResolutionLow : UInt16
	var reserved_x1 : UInt8
	var frameCount : UInt8
	var colourDepth : UInt8
	
	var additionalData_x39 : [UInt8]
	
	var childAtoms : [any Atom]
	var dataAfterChildAtoms : [UInt8]
		

	
	init(header:any Atom,data:inout DataReader) async throws
	{
		//	https://stackoverflow.com/a/43617477/355753
		//	https://github.com/NewChromantics/PopCodecs/blob/master/PopMpeg4.cs#L1024
		//	stsd isn't very well documented
		//	https://www.cimarronsystems.com/wp-content/uploads/2017/04/Elements-of-the-H.264-VideoAAC-Audio-MP4-Movie-v2_0.pdf
		//auto SampleDescriptionSize = Reader.Read32();
		//auto CodecFourcc = Reader.ReadString(4);
		self.reserved_x6 = Array(try await data.ReadBytes(6))
		self.dataReferenceIndex = try await data.Read16();
		
		self.predefines_x16 = Array(try await data.ReadBytes(16))
		self.mediaWidth = try await data.Read16();
		self.mediaHeight = try await data.Read16();
		self.horzResolution = try await data.Read16();
		self.horzResolutionLow = try await data.Read16();
		self.vertResolution = try await data.Read16();
		self.vertResolutionLow = try await data.Read16();
		self.reserved_x1 = try await data.Read8();
		self.frameCount = try await data.Read8();
		self.colourDepth = try await data.Read8();
		
		//	gr: some magic number
		self.additionalData_x39 = Array(try await data.ReadBytes(39))
		
		//	now there's more atoms!
		self.childAtoms = []
		
		while data.bytesRemaining > 0
		{
			do
			{
				let child = try await data.ReadAtom()
				childAtoms.append(child)
			}
			catch
			{
				childAtoms.append(ErrorAtom(errorContext: "decoding sub atom", error: error,parent: header))
				break
			}
		}
		
		self.dataAfterChildAtoms = []
		if data.bytesRemaining > 0
		{
			self.dataAfterChildAtoms = Array(try await data.ReadBytes(Int(data.bytesRemaining)))
		}
	}
	
	
	func GetMetaAtoms(parent:any Atom,uidOffset:Int=0) -> [InfoAtom]
	{
		let metas : [String:Any] = [
			"Predefines":predefines_x16,
			"MediaWidth":mediaWidth,
			"MediaHeight":mediaHeight,
			"HorzResolution":horzResolution,
			"HorzResolutionLow":horzResolutionLow,
			"VertResolution":vertResolution,
			"VertResolutionLow":vertResolutionLow,
			"FrameCount":frameCount,
			"ColourDepth":colourDepth,
		]
		let metaAtoms = metas.enumerated().map
		{
			index,meta in 
			InfoAtom(info:"\(meta.key)=\(meta.value)",parent:parent,uidOffset:uidOffset+index)
		}
		return metaAtoms
	}
}

protocol CodecWithMetaAtoms : Codec
{
	func GetMetaAtoms(parent:any Atom) -> [any Atom]
}

extension H264Codec : CodecWithMetaAtoms
{
}

extension HevcCodec : CodecWithMetaAtoms
{
}

struct Atom_hev1 : Atom, SpecialisedAtom, VideoCodecAtom
{
	static let fourcc = Fourcc("hev1")
	
	var header : AtomHeader
	var videoCodecMeta: VideoCodecMeta
	var codec : CodecWithMetaAtoms?
	var childAtoms : [any Atom]?
	{
		codecMetaAtoms
		+
		videoCodecMeta.GetMetaAtoms(parent: self)
		+
		videoCodecMeta.childAtoms
	}
	var codecMetaAtoms : [any Atom]	{	codec?.GetMetaAtoms(parent: self) ?? []	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let videoCodecMeta = try await VideoCodecMeta(header: header, data: &content)
		
		let hvcc : Atom_hvcc? = try? videoCodecMeta.childAtoms.GetFirstChildAtomAs(fourcc: Atom_hvcc.fourcc)
		
		return Self(header:header, videoCodecMeta:videoCodecMeta, codec: hvcc?.codec)
	}
}



struct Atom_hvcc : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("hvcC")
	
	var header : AtomHeader 
	var codec : HevcCodec
	var metaAtoms : [InfoAtom]
	
	var childAtoms : [any Atom]?
	{
		metaAtoms +
		codec.GetMetaAtoms(parent:self)
	}
	
	
	static func Decode(header: AtomHeader, content: inout DataReader) async throws -> Self 
	{
		//	https://github.com/axiomatic-systems/Bento4/blob/master/Source/C%2B%2B/Core/Ap4HvccAtom.cpp#L248
		//	https://github.com/FFmpeg/FFmpeg/blob/6c878f8b829bc9da4bbb5196c125e55a7c3ac32f/libavcodec/hevc/parse.c#L91
		
		//	always 2-byte nalu length in header
		let hvccNaluLengthSize = 2
		let isNalff = false	//	not sure what this is yet, but has to do with padding in nalu units
		
		//	ffmpeg just skips first 21 bytes if data>23 bytes
		//	here's the contents
		//	https://github.com/axiomatic-systems/Bento4/blob/master/Source/C%2B%2B/Core/Ap4HvccAtom.cpp#L258C5-L280C55
		let prefixData = try await content.ReadBytes(21)
		let configurationVersion = prefixData[0]
		
		//	ffmpeg: "configurationVersion from 14496-15."
		let predatingStandard = configurationVersion == 0
		if predatingStandard
		{
			throw PopCodecError("hvcc content predates standard - currently unsupported")
		}
		/*
		//if (size >= 23 && (configurationVersion || (predatingStandard && (data[1] || data[2] > 1)))) {
		let hasHeader = content.bytesRemaining >= 23 && configurationVersion
		if !hasHeader
		{
			throw PopCodecError("hvcc content has no header - currently unsupported")
		}
*/
		let packetMeta = try await content.Read8()
		let constantFrameRate = (packetMeta >> 6) & 0x03
		let temporalLayerCount = (packetMeta >> 3) & 0x07
		let temporalIdNested = (packetMeta >> 2) & 0x01
		let naluLengthSizeMinusOne = (packetMeta) & 0x03
		let fileNaluLengthSize = naluLengthSizeMinusOne + 1
		
		let parameterCount = try await content.Read8()	//	num_arrays in ffmpeg

		var metaAtoms : [InfoAtom] = []
		metaAtoms.append(InfoAtom(info: "constantFrameRate=\(constantFrameRate)", parent: header, uidOffset: metaAtoms.count))
		metaAtoms.append(InfoAtom(info: "temporalLayerCount=\(temporalLayerCount)", parent: header, uidOffset: metaAtoms.count))
		metaAtoms.append(InfoAtom(info: "temporalIdNested=\(temporalIdNested)", parent: header, uidOffset: metaAtoms.count))
		metaAtoms.append(InfoAtom(info: "NaluLengthSize=\(fileNaluLengthSize)", parent: header, uidOffset: metaAtoms.count))
		metaAtoms.append(InfoAtom(info: "parameterCount=\(parameterCount)", parent: header, uidOffset: metaAtoms.count))

		var parameters : [HevcParameter] = []

		for parameterIndex in 0..<parameterCount
		{
			let filePosition = content.globalPosition
			let parameterHeader = try await content.Read8()

			//	expecting this to be a stream of nalu packets
			let naluCount = try await content.Read16()	//	big endian
			
			var parameter = HevcParameter(filePosition:filePosition, parameterHeader:parameterHeader, naluCount:naluCount, nalus: [])
			
			for naluIndex in 0..<naluCount
			{
				// +2 for the nal size field
				let naluContentSize = try await content.Read16()
				let naluTotalSize = Int(naluContentSize) + hvccNaluLengthSize
				let naluPosition = content.globalPosition
				let nalBytes = try await content.ReadBytes(naluTotalSize - 2)	//	- content size we already read
				//metaAtoms.append( InfoAtom(info: "Packet(\(packetType)) #\(packetIndex) Nalu #\(naluIndex)/\(naluCount) size=\(naluTotalSize)", parent: header, filePosition: naluPosition, totalSize: UInt64(naluTotalSize)) )

				let nalu = HevcNalu(contentSize: naluContentSize, dataWithoutLengthPrefix: Array(nalBytes), filePosition: naluPosition)
				parameter.nalus.append(nalu)
				/*
				ret = hevc_decode_nal_units(gb.buffer, nalsize, ps, sei, *is_nalff,
											*nal_length_size, err_recognition, apply_defdispwin,
											logctx);
				if (ret < 0) {
					av_log(logctx, AV_LOG_ERROR,
						   "Decoding nal unit %d %d from hvcC failed\n",
						   type, i);
					return ret;
				}*/
			}
			
			parameters.append(parameter)
		}

		if content.bytesRemaining > 0
		{
			let unreadPosition = content.globalPosition
			let bytes = try await content.ReadBytes(Int(content.bytesRemaining))
			metaAtoms.append( InfoAtom(info: "Unread bytes=\(bytes.count)", filePosition: unreadPosition, totalSize: UInt64(bytes.count)))
		}
		
		let hevc = HevcCodec(parameters: parameters, naluHeaderSize: fileNaluLengthSize)
		let atom = Self(header:header,codec: hevc,metaAtoms: metaAtoms)
		return atom
	}
}

//	like hevc, and hvcc. Atom often used by apple instead of hevc
struct Atom_hvc1 : Atom, SpecialisedAtom, VideoCodecAtom
{
	static let fourcc = Fourcc("hvc1")
	
	var header : AtomHeader
	var videoCodecMeta: VideoCodecMeta
	var codec : CodecWithMetaAtoms?
	var childAtoms : [any Atom]?
	{
		codecMetaAtoms
		+
		videoCodecMeta.GetMetaAtoms(parent: self)
		+
		videoCodecMeta.childAtoms
	}
	var codecMetaAtoms : [any Atom]	{	codec?.GetMetaAtoms(parent: self) ?? []	}
	
	
	static func Decode(header: AtomHeader, content: inout DataReader) async throws -> Self 
	{
		let videoCodecMeta = try await VideoCodecMeta(header: header, data: &content)
		
		let hvcc : Atom_hvcc? = try? videoCodecMeta.childAtoms.GetFirstChildAtomAs(fourcc: Atom_hvcc.fourcc)
		
		return Self(header:header, videoCodecMeta:videoCodecMeta, codec: hvcc?.codec)
	}
}


struct Atom_trak : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("trak")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?	{	metaAtoms + children	}
	var children : [any Atom]
	var metaAtoms : [any Atom]
	{[
		//	these are producing duplicate IDs (file offsets) when there's an erro
		InfoAtom(info: "\(encoding)", icon:encoding.icon, parent: self, uidOffset: 1),
		InfoAtom(info: "\(samplesInFileOrder.count) samples", parent: self, uidOffset: 2),
		decodeSamplesError.map{ ErrorAtom(errorContext: "Decoding samples", error: $0, parent: self, uidOffset:3) }
	].compactMap{$0}
	}
	var encoding : TrackEncoding
	var samplesInFileOrder : [Mp4Sample]		//	order in file
	var samplesInPresentationOrder : [Mp4Sample]
	{
		samplesInFileOrder.sorted{ a,b in a.presentationTime < b.presentationTime}
	}
	var decodeSamplesError : Error?
	
	static func Decode(header: AtomHeader, content: inout DataReader) async throws -> Atom_trak 
	{
		//	do default here, we just need specialisation of trak so we can find it
		let children = try await header.AutoDecodeChildAtoms(content: &content)

		var encoding = TrackEncoding.Unknown
		
		let videoCodecAtom = try? children.GetFirstChildAtom
		{
			atom in
			return atom is VideoCodecAtom
		} as? VideoCodecAtom
		
		if let videoCodecAtom// as? VideoCodecAtom
		{
			encoding = .Video(videoCodecAtom.codec ?? MissingCodec())
		}
		
		if let mp4a = try? children.GetFirstChildAtom(fourcc: Atom_mp4a.fourcc)
		{
			encoding = .Audio
		}
		
		if let text = try? children.GetFirstChildAtom(fourcc: Atom_text.fourcc)
		{
			encoding = .Text
		}

		let mediaHeaderAtom : Atom_mdhd? = try? children.GetFirstChildAtomAs(fourcc: Atom_mdhd.fourcc)
		let mediaMeta = mediaHeaderAtom?.mediaMeta
		
		
		let sampleTable : Atom_stbl = try children.GetFirstChildAtomAs(fourcc: Atom_stbl.fourcc)
		var decodeSamplesError : Error?
		let samples : [Mp4Sample]
		do
		{
			samples = try sampleTable.DecodeSamples(mediaMeta: mediaMeta)
		}
		catch
		{
			samples = []
			decodeSamplesError = error
		}
		
		return Atom_trak(header: header, children:children, encoding: encoding, samplesInFileOrder: samples, decodeSamplesError:decodeSamplesError)
	}
}

struct Atom_mp4a : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("mp4a")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let children = try await header.AutoDecodeChildAtoms(content: &content)
		return Atom_mp4a(header:header, childAtoms:children)
	}
}


struct TextTrackMeta
{
	func GetMetaAtoms(parent:any Atom) -> [any Atom]
	{[
		InfoAtom(info:"displayFlags \(self.displayFlags)",parent: parent,uidOffset: 0),
		InfoAtom(info:"textJustification \(self.textJustification)",parent: parent,uidOffset: 1),
		InfoAtom(info:"backgroundRed \(self.backgroundRed)",parent: parent,uidOffset: 2),
		InfoAtom(info:"backgroundGreen \(self.backgroundGreen)",parent: parent,uidOffset: 3),
		InfoAtom(info:"backgroundBlue \(self.backgroundBlue)",parent: parent,uidOffset: 4),
		InfoAtom(info:"defaultTextBoxTop \(self.defaultTextBoxTop)",parent: parent,uidOffset: 5),
		InfoAtom(info:"defaultTextBoxLeft \(self.defaultTextBoxLeft)",parent: parent,uidOffset: 6),
		InfoAtom(info:"defaultTextBoxBottom \(self.defaultTextBoxBottom)",parent: parent,uidOffset: 7),
		InfoAtom(info:"defaultTextBoxRight \(self.defaultTextBoxRight)",parent: parent,uidOffset: 8),
		InfoAtom(info:"reserved0 \(self.reserved0)",parent: parent,uidOffset: 9),
		InfoAtom(info:"reserved1 \(self.reserved1)",parent: parent,uidOffset: 10),
		InfoAtom(info:"fontNumber \(self.fontNumber)",parent: parent,uidOffset: 11),
		InfoAtom(info:"fontStyle \(self.fontStyle)",parent: parent,uidOffset: 12),
		InfoAtom(info:"reserved2 \(self.reserved2)",parent: parent,uidOffset: 13),
		InfoAtom(info:"reserved3 \(self.reserved3)",parent: parent,uidOffset: 14),
		InfoAtom(info:"foregroundRed \(self.foregroundRed)",parent: parent,uidOffset: 15),
		InfoAtom(info:"foregroundGreen \(self.foregroundGreen)",parent: parent,uidOffset: 16),
		InfoAtom(info:"foregroundBlue \(self.foregroundBlue)",parent: parent,uidOffset: 17),
	]}
	
	var displayFlags : UInt32
	var textJustification : UInt32
	var backgroundRed : UInt16
	var backgroundGreen : UInt16
	var backgroundBlue : UInt16
	var defaultTextBoxTop : UInt16
	var defaultTextBoxLeft : UInt16
	var defaultTextBoxBottom : UInt16
	var defaultTextBoxRight : UInt16
	var reserved0 : UInt32
	var reserved1 : UInt32
	var fontNumber : UInt16
	var fontStyle : UInt16
	var reserved2 : UInt8
	var reserved3 : UInt16
	var foregroundRed : UInt16
	var foregroundGreen : UInt16
	var foregroundBlue : UInt16
}

struct Atom_text : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("text")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{
		meta.GetMetaAtoms(parent: self) +
		[
		InfoAtom(info:"string [\(self.string)]",parent: self,uidOffset: 18),
		InfoAtom(info:"unreadBytes [\(self.unreadBytes)]",parent: self,uidOffset: 19),
		]
	}
	
	var meta : TextTrackMeta
	var string : String
	var unreadBytes : Int
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		//	same prefix as atom_avc1
		let reserved00000 = try await content.ReadBytes(6)
		let dataReferenceIndex = try await content.Read16()

		//	https://developer.apple.com/documentation/quicktime-file-format/text_sample_description
		let meta : TextTrackMeta = try await content.ReadAs()

		let stringLength = try await content.Read8()
		let stringChars = try await content.ReadBytes(Int(stringLength))
		let string = String(bytes: stringChars, encoding: .ascii) ?? "Failed to parse ascii string"

		let unreadBytes = Int(content.bytesRemaining)
		
		return Self(header:header, meta:meta, string: string, unreadBytes: unreadBytes)
	}
}



public struct Mp4Sample : Hashable
{
	public var mdatOffset : UInt64	//	file position but inside it's mdat
	public var size : UInt32
	public var decodeTime : UInt64
	public var presentationTime : UInt64
	public var presentationEndTime : UInt64	{	presentationTime + duration }
	public var duration : UInt64
	public var isKeyframe : Bool
}

public struct Mp4SampleAndDependencies
{
	var sample : Mp4Sample
	var dependences : [Mp4Sample]
	
	var samplesInDecodeOrder : [Mp4Sample]
	{
		//	check for error with input - do this at init?	
		//var allSamples = [sample] + dependences
		var allSamples = dependences
		let dependenciesContainsSample = dependences.contains{ $0.decodeTime == sample.decodeTime }
		if !dependenciesContainsSample
		{
			allSamples.append(sample)
		}
		allSamples = allSamples.sorted{ a,b in a.decodeTime < b.decodeTime }
		return allSamples
	}
}


struct Atom_stsz : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("stsz")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{[
		InfoAtom(info: "\(sampleSizes.count) sample sizes", parent: self, uidOffset: 0)
	]}
	
	//var version : UInt8
	//var flags : UInt32
	var sampleSizes : [UInt32]
	
	static func ReadSizes(content:inout DataReader) async throws -> [UInt32]
	{
		let Version = try await content.Read8();
		let Flags = try await content.Read24();
		var sampleSize = try await content.Read32();
		let EntryCount = try await content.Read32();
		
		//	if size specified, they're all this size
		if sampleSize != 0
		{
			let sizes = Array(repeating: sampleSize, count: Int(EntryCount))
			return sizes
		}
		
		var sizes : [UInt32] = []
		
		//	each entry in the table is the size of a sample (and one chunk can have many samples)
		let startPosition = content.position
		//	gr: docs don't say size, but this seems accurate...
		//		but also sometimes doesnt SEEM to match the size in the header?
		//SampleSize = (Atom.ContentSize() - SampleSizeStart) / EntryCount;
		sampleSize = UInt32(content.bytesRemaining) / EntryCount
		
		//	fast option
		if sampleSize == 4
		{
			sizes = Array(repeating:UInt32(0), count:Int(EntryCount))
			try await content.ReadBytes(to: &sizes)
			sizes = sizes.map{ $0.bigEndian }
		}
		else
		{
			for e in 0..<EntryCount
			{
				if sampleSize == 3
				{
					let size = try await content.Read24();
					sizes.append(size)
				}
				else if sampleSize == 4
				{
					let size = try await content.Read32();
					sizes.append(size)
				}
				else
				{
					throw PopCodecError("Unhandled sample size \(sampleSize)")
				}
			}
		}
		
		return sizes
	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let sizes = try await ReadSizes(content: &content)
		
		return Self(header: header, sampleSizes: sizes)
	}
}


struct Atom_ctts : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("ctts")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{[
		InfoAtom(info: "\(presentationTimeOffsets.count) sample presentation offsets", parent: self, uidOffset: 0)
	]}
	
	var version : UInt8
	var flags : UInt32
	var presentationTimeOffsets : [Int32]	//	these can be negative!
	
	static func DecodeRle(content:inout DataReader) async throws -> (UInt8,UInt32,[Int32])
	{
		let version = try await content.Read8()
		let flags = try await content.Read24()
		let entryCount = try await content.Read32()
		
		var countAndDurations = Array(repeating:(UInt32(0),Int32(0)), count: Int(entryCount))
		try await content.ReadBytes(to: &countAndDurations)
		
		let durations = countAndDurations.flatMap
		{
			count_le,duration_le in
			let count = count_le.bigEndian
			let duration = duration_le.bigEndian
			return Array(repeating: duration, count: Int(count)) 
		}
		return (version,flags,durations)
	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let (version,flags,durations) = try await DecodeRle(content: &content)

		return Self(header: header, version: version, flags: flags, presentationTimeOffsets: durations)
	}
}


struct Atom_stts : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("stts")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{[
		InfoAtom(info: "\(sampleDurations.count) sample durations", parent: self, uidOffset: 0)
	]}
	
	var version : UInt8
	var flags : UInt32
	var sampleDurations : [UInt32]	//	can these be negative? presentation offsets can be
	
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let (version,flags,durations) = try await Atom_ctts.DecodeRle(content: &content)
		let durationsUnsigned = durations.map{ UInt32($0)	}
		return Self(header: header, version: version, flags: flags, sampleDurations: durationsUnsigned)
	}
}



//	sample table
struct Atom_stbl : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("stbl")
	
	var header : AtomHeader

	var childAtoms : [any Atom]?	{	children	} 
	var children : [any Atom]
	
	
	func DecodeSamples(mediaMeta:MediaMeta?) throws -> [Mp4Sample]
	{
		let mediaMeta = mediaMeta ?? MediaMeta()
		
		//	sizes always exist
		let sampleSizesAtom : Atom_stsz = try children.GetFirstChildAtomAs(fourcc:Atom_stsz.fourcc)
		let sampleSizes = sampleSizesAtom.sampleSizes
		
		let keyframesAtom : Atom_stss? = try? children.GetFirstChildAtomAs(fourcc: Atom_stss.fourcc)
		let keyframeIndexes = Set(keyframesAtom?.keyframeIndexes ?? [])
		
		let sampleDurationsAtom : Atom_stts = try children.GetFirstChildAtomAs(fourcc:Atom_stts.fourcc)
		let sampleDurations = sampleDurationsAtom.sampleDurations
		//	gr: this doesn't always exist
		//	the presentation offset is offset from the decode time
		let presentationTimeOffsetsAtom : Atom_ctts? = try? children.GetFirstChildAtomAs(fourcc:Atom_ctts.fourcc)
		let defaultPresentationTimeOffsets = Array(repeating: Int32(0), count: sampleSizes.count)
		let presentationTimeOffsets = presentationTimeOffsetsAtom?.presentationTimeOffsets ?? defaultPresentationTimeOffsets
		
		let chunkMetaAtom : Atom_stsc = try children.GetFirstChildAtomAs(fourcc: Atom_stsc.fourcc)
		let chunkOffsets32Atom : Atom_stco? = try? children.GetFirstChildAtomAs(fourcc: Atom_stco.fourcc)
		let chunkOffsets64Atom : Atom_co64? = try? children.GetFirstChildAtomAs(fourcc: Atom_co64.fourcc)
		let chunkOffsetsAtom : Atom_WithChunkOffsets? = chunkOffsets32Atom ?? chunkOffsets64Atom
		guard let chunkOffsetsAtom else
		{
			throw PopCodecError("No 32bit (stco) or 64bit (co64) chunk offsets atom")
		}
		let chunkOffsets = chunkOffsetsAtom.chunkOffsets
		let chunkMetas = chunkMetaAtom.GetUnpackedChunkMetas(chunkCount: chunkOffsets.count)

		//	merge all samples
		var currentDecodeTime : UInt32 = 0
		var samples : [Mp4Sample] = []
		
		//	merge samples chunk by chunk
		for (chunkIndex,chunkMeta) in chunkMetas.enumerated()
		{
			var chunkFilePosition = UInt64(chunkOffsets[chunkIndex])
			//auto SampleMeta = ChunkMetas[i];
			//auto ChunkIndex = i;
			//auto ChunkFileOffset = ChunkOffsets[ChunkIndex];
			
			for _ in 0..<chunkMeta.samplesPerChunk
			{
				let sampleIndex = samples.count
				
				//let presentationTimeOffset = sampleIndex == 0 ? 0 : presentationTimeOffsets[sampleIndex-1]
				let presentationTimeOffset = presentationTimeOffsets[sampleIndex]

				let sampleDuration = sampleDurations[sampleIndex]
				let sampleDecodeTime = currentDecodeTime
				let samplePresentationTime = UInt32( Int32(sampleDecodeTime) + presentationTimeOffset )

				//	convert to proper time
				let frameDuration = mediaMeta.TimeUnitToMilliseconds(time: sampleDuration)
				let frameDecodeTime = mediaMeta.TimeUnitToMilliseconds(time: sampleDecodeTime)
				let framePresentationTime = mediaMeta.TimeUnitToMilliseconds(time: samplePresentationTime)
				
				let isKeyframe = keyframeIndexes.contains(UInt32(sampleIndex))
				let sampleSize = sampleSizes[sampleIndex]
				let sample = Mp4Sample(mdatOffset: chunkFilePosition, size: sampleSize, decodeTime: frameDecodeTime, presentationTime: framePresentationTime, duration: frameDuration, isKeyframe: isKeyframe)
				
				currentDecodeTime += sampleDuration
				chunkFilePosition += UInt64(sampleSize)
				
				samples.append(sample)
			}
		}
		
		return samples
	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let children = try await header.AutoDecodeChildAtoms(content: &content)
		
		return Atom_stbl(header:header, children: children)
	}
}

//	sample "syncs" (keyframes)
struct Atom_stss : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("stss")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{[
		InfoAtom(info: "\(keyframeIndexes.count) keyframes", parent: self, uidOffset: 0)
	]}
	
	//var version : UInt8
	//var flags : UInt32
	var keyframeIndexes : [UInt32]
	
	static func ReadKeyframeIndexes(content:inout DataReader) async throws -> [UInt32]
	{
		let Version = try await content.Read8();
		let Flags = try await content.Read24();
		let EntryCount = try await content.Read32();
		
		if EntryCount == 0
		{
			return []
		}
		
		var keyframeIndexes : [UInt32] = []
		
		//	gr: docs don't say size, but this seems accurate...
		let IndexSize = UInt32(content.bytesRemaining) / EntryCount;
		for e in 0..<EntryCount
		{
			var SampleIndex : UInt32
			if IndexSize == 3
			{
				SampleIndex = try await content.Read24();
			}
			else if IndexSize == 4
			{
				SampleIndex = try await content.Read32();
			}
			else
			{
				throw BadDataError("Unhandled index size \(IndexSize)")
			}
			
			//	gr: indexes start at 1
			SampleIndex -= 1
			keyframeIndexes.append(SampleIndex) 
		}
		return keyframeIndexes;
	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let keyframeIndexes = try await ReadKeyframeIndexes(content: &content)
		
		return Self(header: header, keyframeIndexes: keyframeIndexes)
	}
}

protocol Atom_WithChunkOffsets
{
	var chunkOffsets : [UInt64]	{	get	}
}

struct Atom_stco : Atom, SpecialisedAtom, Atom_WithChunkOffsets
{
	static let fourcc = Fourcc("stco")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{[
		InfoAtom(info: "\(chunkOffsets.count) sample chunk offsets", parent: self, uidOffset: 0),
		InfoAtom(info: "version: \(version)", parent: self, uidOffset: 1),
		InfoAtom(info: "flags: \(flags)", parent: self, uidOffset: 2),
	]}
	
	var version : UInt8
	var flags : UInt32
	var chunkOffsetsLittleEndian : [UInt32]
	var chunkOffsets : [UInt64]	{	chunkOffsetsLittleEndian.map{ UInt64($0.bigEndian) }	}
	
	static func DecodeOffsets(content:inout DataReader) async throws -> (UInt8,UInt32,[UInt32])
	{
		let version = try await content.Read8()
		let flags = try await content.Read24()
		let entryCount = try await content.Read32();
		
		var offsets = Array(repeating:UInt32(0), count: Int(entryCount) )
		try await content.ReadBytes(to:&offsets)
		return (version,flags,offsets)
	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let (version,flags,offsets) = try await DecodeOffsets(content: &content)
		
		return Self(header: header, version: version, flags: flags, chunkOffsetsLittleEndian: offsets)
	}
}


struct Atom_co64 : Atom, SpecialisedAtom, Atom_WithChunkOffsets
{
	static let fourcc = Fourcc("co64")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{[
		InfoAtom(info: "\(chunkOffsets.count) sample chunk offsets", parent: self, uidOffset: 0),
		InfoAtom(info: "version: \(version)", parent: self, uidOffset: 1),
		InfoAtom(info: "flags: \(flags)", parent: self, uidOffset: 2),
	]}
	
	var version : UInt8
	var flags : UInt32
	var chunkOffsetsLittleEndian : [UInt64]
	var chunkOffsets : [UInt64]	{	chunkOffsetsLittleEndian.map{ $0.bigEndian }	}
	
	static func DecodeOffsets(content:inout DataReader) async throws -> (UInt8,UInt32,[UInt64])
	{
		let version = try await content.Read8()
		let flags = try await content.Read24()
		let entryCount = try await content.Read32();
		
		var offsets = Array(repeating:UInt64(0), count: Int(entryCount) )
		try await content.ReadBytes(to:&offsets)
		return (version,flags,offsets)
	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let (version,flags,offsets) = try await DecodeOffsets(content: &content)
		
		return Self(header: header, version: version, flags: flags, chunkOffsetsLittleEndian: offsets)
	}
}


//	sample to sample-chunk-meta
struct Atom_stsc : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("stsc")
	
	var header : AtomHeader
	var childAtoms : [any Atom]?
	{[
		InfoAtom(info: "\(packedChunkMetas.count) packed sample chunks", parent: self, uidOffset: 0),
		InfoAtom(info: "version: \(version)", parent: self, uidOffset: 1),
		InfoAtom(info: "flags: \(flags)", parent: self, uidOffset: 2),
	]}
	
	var version : UInt8
	var flags : UInt32
	var packedChunkMetas : [SampleChunkMeta]
	
	func GetUnpackedChunkMetas(chunkCount:Int) -> [SampleChunkMeta]
	{
		var chunkMetas : [SampleChunkMeta] = []
		
		//	pad (fill in gaps) the metas to fit offset information
		//	https://sites.google.com/site/james2013notes/home/mp4-file-format
		for packedChunkMeta in packedChunkMetas 
		{
			//var chunkMet
			//auto ChunkMeta = PackedChunkMetas[i];
			//	first begins at 1. despite being an index...
			let firstChunk = packedChunkMeta.firstChunk - 1
			//auto FirstChunk = ChunkMeta.FirstChunk - 1;
			//	pad previous up to here
			while chunkMetas.count < firstChunk
			{
				chunkMetas.append( chunkMetas.last! )
			}
			
			chunkMetas.append(packedChunkMeta)
		}
		//	and pad the end
		while chunkMetas.count < chunkCount
		{
			chunkMetas.append( chunkMetas.last! )
		}
		return chunkMetas
	}
	
	static func DecodeChunkMetas(content:inout DataReader) async throws -> (UInt8,UInt32,[SampleChunkMeta])
	{
		let flags = try await content.Read24();
		let version = try await content.Read8();
		let entryCount = try await content.Read32();
		
		var chunkMetas = Array(repeating: SampleChunkMeta(), count: Int(entryCount))
		try await content.ReadBytes(to: &chunkMetas)
		
		return (version,flags,chunkMetas)
	}
	
	static func Decode(header: AtomHeader, content:inout DataReader) async throws -> Self 
	{
		let (version,flags,chunkMetas) = try await DecodeChunkMetas(content: &content)
		
		return Self(header: header, version: version, flags: flags, packedChunkMetas: chunkMetas)
	}
}


struct Atom_mdhd : Atom, SpecialisedAtom
{
	static let fourcc = Fourcc("mdhd")
	
	var header : AtomHeader
	var mediaMeta : MediaMeta
	var childAtoms: [any Atom]?	{	metaAtoms	}
	var metaAtoms : [any Atom]	{	mediaMeta.GetMetaAtoms(parent: self)	}
	
	static func Decode(header: AtomHeader, content: inout DataReader) async throws -> Self 
	{
		var meta = MediaMeta()
		meta.version = try await content.Read8();
		meta.flags = try await content.Read24();
		meta.creationTime_SecondsSinceJan1st1904 = try await content.Read32();
		meta.modificationTime_SecondsSinceJan1st1904 = try await content.Read32();
		meta.timeUnitsPerSecond = try await content.Read32();
		meta.durationTimeUnit = try await content.Read32();
		meta.language = try await content.Read16();
		meta.quality16 = try await content.Read16();
		
		return Atom_mdhd(header: header, mediaMeta: meta)
	}
}
