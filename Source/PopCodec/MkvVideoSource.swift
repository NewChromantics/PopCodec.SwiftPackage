import Foundation
import PopCommon


extension ByteReader
{
	//	read header, contents follow
	mutating func ReadEbmlElementHeader() async throws -> EBMLElement
	{
		let startingPosition = self.globalPosition
		let id = try await ReadEbmlElementId()
		let contentSize = try await readVIntSize()
		
		//	check how many bytes we've read
		let currentPosition = self.globalPosition
		let bytesRead = currentPosition - startingPosition
		let headerSize = bytesRead
		return EBMLElement(id: id, contentSize: contentSize, filePosition: startingPosition, headerSize: headerSize)
	}
	
	//	very slightly different to readVIntSize()
	mutating func ReadEbmlElementId() async throws -> UInt32
	{
		let firstByte = try await Read8()
		var length = 0
		var mask: UInt8 = 0x80
		
		// Determine length by finding first set bit
		for i in 0..<8 {
			if (firstByte & mask) != 0 {
				length = i + 1
				break
			}
			mask >>= 1
		}
		
		guard length > 0 && length <= 4 else {
			throw MKVError.invalidElementID
		}
		
		// Read all bytes including the marker bit
		var value: UInt32 = UInt32(firstByte)
		//offset += 1
		
		for _ in 1..<length 
		{
			let nextByte = try await Read8()
			value = (value << 8) | UInt32(nextByte)
		}
		
		return value
	}
	
	//	variable length int
	mutating func readVIntSize() async throws -> UInt64 
	{
		let firstByte = try await Read8()
		var length = 0
		var mask: UInt8 = 0x80
		
		for i in 0..<8 {
			if (firstByte & mask) != 0 {
				length = i + 1
				break
			}
			mask >>= 1
		}
		
		guard length > 0 else {
			throw MKVError.invalidVInt
		}
		
		// Strip the marker bit for size values
		var value: UInt64 = UInt64(firstByte & (mask - 1))
		
		for _ in 1..<length 
		{
			let nextByte = try await Read8()
			value = (value << 8) | UInt64(nextByte)
		}
		
		return value
	}
}


extension MkvTrackMeta
{
	func GetEncoding() async -> TrackEncoding
	{
		switch self.metadata
		{
			case .audio(let meta):	
				return .Audio
				
			case .text(let meta):	
				return .Text
			
			case .video(let meta):
				let codec = try? await GetVideoCodec(codecData: meta.codecPrivate)
				return .Video(codec ?? MissingCodec())
				
			default:		
				return .Unknown
		}
	}
	
	func GetVideoCodec(codecData:Data?) async throws -> any Codec
	{
		guard let codecData else
		{
			throw DataNotFound("Missing codec data for \(codecID)")
		}
		let hevcId = "V_MPEGH/ISO/HEVC"
		let h264Id = "V_MPEG4/ISO/AVC"
		if codecID == h264Id
		{
			//	data is avcc atom
			let dummyAtomHeader = try AtomHeader(fourcc: Atom_avcc.fourcc, filePosition: 0, size: UInt32(codecData.count), size64: nil )
			var dataReader = DataReader(data: codecData)
			let atom = try await Atom_avcc.Decode(header: dummyAtomHeader, content: &dataReader)
			return atom.codec
		}
		
		if codecID == hevcId
		{
			//	data is avcc atom
			let dummyAtomHeader = try AtomHeader(fourcc: Atom_hvcc.fourcc, filePosition: 0, size: UInt32(codecData.count), size64: nil)
			var dataReader = DataReader(data: codecData)
			let atom = try await Atom_hvcc.Decode(header: dummyAtomHeader, content: &dataReader)
			return atom.codec
		}
		
		throw PopCodecError("Unknown video codec \(codecID)")
	}
}

struct MkvHeader
{
	var atoms : [any Atom]
	
	var tracks : [TrackMeta]
}



public class MkvVideoSource : VideoSource
{
	public var typeName: String	{"Matroska"}
	public var defaultSelectedTrack: TrackUid? = nil
	
	var url : URL
	
	//	we parse the whole file as its a chunked format 
	var parseFileTask : Task<Void,Error>!
	var headerPromise = SendablePromise<MkvHeader>()
	
	required public init(url:URL)
	{
		self.url = url
		
		parseFileTask = Task(operation: ParseFile)
	}
	
	func ParseFile() async throws
	{
		var fileData = try Data(contentsOf:url, options: .uncached)
		var fileReader = DataReader(data: fileData)

		let documentMeta = try await fileReader.ReadEbmlDocumentMetaElement()
		
		do
		{
			let header = try await ReadHeader(fileReader: fileReader)
			headerPromise.Resolve(header)
		}
		catch
		{
			headerPromise.Reject(error)
		}
	}
	
	func ReadHeader(fileReader:DataReader) async throws -> MkvHeader
	{
		var fileData = try Data(contentsOf:url, options: .uncached)
		var fileReader = DataReader(data: fileData)
		let parser = MKVParser(data: fileData)
		
		var atoms : [any Atom] = [] 
		
		let doc = try await parser.parse(fileReader: &fileReader)
		{
			element in
			atoms.append(element)
		}		
		
		
		//	this is async because of data reader, so precalc it for sync .map
		var trackEncoding : [UInt64:TrackEncoding] = [:]
		for track in doc.tracks
		{
			let encoding = await track.GetEncoding()
			trackEncoding[track.uid] = encoding
		}
		
		
		let trackMetas = doc.tracks.map
		{
			track in
			
			let trackUid = track.name ?? "\(track.number)"////"\(track.uid)"
			var duration = track.defaultDuration ?? 0 
			var trackStartTime = Millisecond(0)
			let encoding = trackEncoding[track.uid]!
			
			let allSamples = doc.clusters.flatMap
			{
				cluster in
				return cluster.samples
			}
			let trackSamples = allSamples.filter{ $0.trackNumber == track.number }
			let samples = trackSamples.map
			{
				mkvSample in
				let filePosition = UInt64(mkvSample.fileOffset)
				let size = UInt32(mkvSample.size)
				let presentationTime = Millisecond(mkvSample.timestamp)
				let decodeTime = Millisecond(mkvSample.decodeTimestamp) ?? presentationTime
				let duration = mkvSample.duration ?? track.defaultDuration ?? 0
				return Mp4Sample(mdatOffset: filePosition, size: size, decodeTime: decodeTime, presentationTime: presentationTime, duration: duration, isKeyframe: mkvSample.isKeyframe)
			}
			
			
			if let firstSample = samples.first, let lastSample = samples.last
			{
				
				duration = lastSample.presentationEndTime - firstSample.presentationTime
			}
			return TrackMeta(id: trackUid, startTime: trackStartTime, duration: duration, encoding: encoding, samples: samples)
		}
		
		let header = MkvHeader(atoms: atoms, tracks: trackMetas)

		defaultSelectedTrack = trackMetas.first{$0.encoding.isVideo}?.id
		
		return header
	}
	
	public func GetTrackMetas() async throws -> [TrackMeta] 
	{
		let header = try await headerPromise.value
		return header.tracks
	}
	
	public func GetAtoms() async throws -> [any Atom] 
	{
		let header = try await headerPromise.value
		return header.atoms
	}
	
	public func GetAtomData(atom: any Atom) async throws -> Data 
	{
		return try await GetFileData(position: atom.filePosition, size: atom.totalSize)
	}
	
	
	//func GetFrameData(frame:TrackAndTime,keyframe:Bool) async throws -> Data
	public func GetFrameData(frame:TrackAndTime) async throws -> Data
	{
		let keyframe = false
		let sample = try await GetFrameSample(frame: frame,keyframe:keyframe)
		return try await GetFrameData(sample: sample)
	}
	
	func GetFrameData(sample:Mp4Sample) async throws -> Data
	{
		return try await GetFileData(position: sample.mdatOffset, size: UInt64(sample.size))
	}
	
	private func GetFileData(position:UInt64,size:UInt64) async throws -> Data
	{
		if size == 0
		{
			return Data()
		}
		let fileData = try Data(contentsOf:url, options: .alwaysMapped)
		let byteFirstIndex = position
		let byteLastIndex = byteFirstIndex + size - 1
		if byteFirstIndex < 0 || byteLastIndex >= fileData.count
		{
			throw BadDataError("File position \(byteFirstIndex)...\(byteLastIndex) out of bounds (\(fileData.count))")
		}
		let slice = fileData[byteFirstIndex...byteLastIndex]
		
		//	something about this Data() goes out of scope...
		let copy = Data(slice)
		return copy
	}
	
	func GetFrameSample(frame:TrackAndTime,keyframe:Bool) async throws -> Mp4Sample
	{
		let track = try await GetTrackMeta(trackUid: frame.track)
		return try await GetFrameSample(track: track, presentationTime: frame.time, keyframe:keyframe)
	}
	
	func GetFrameSample(track:TrackMeta,presentationTime:Millisecond,keyframe:Bool) async throws -> Mp4Sample
	{
		guard let sample = track.GetSampleLessOrEqualToTime(presentationTime, keyframe: keyframe) else
		{
			throw DataNotFound("No such sample close to \(presentationTime)")
		}
		return sample
	}
	
	func GetFrameSampleAndDependencies(track:TrackMeta,presentationTime:Millisecond,keyframe:Bool) async throws -> Mp4SampleAndDependencies
	{
		//	todo: need to also get samples ahead of this for B-frames! need to start probing the h264 data
		guard let sampleIndex = track.GetSampleIndexLessOrEqualToTime(presentationTime, keyframe: keyframe) else
		{
			throw DataNotFound("No such sample close to \(presentationTime)")
		}
		
		let thisSample = track.samples[sampleIndex]
		if thisSample.isKeyframe
		{
			return Mp4SampleAndDependencies(sample: thisSample,dependences: [])
		}
		
		
		//	get all samples between keyframes
		let prevKeyframeIndex = try
		{
			for prevIndex in (0..<sampleIndex).reversed()
			{
				let prevSample = track.samples[prevIndex]
				if prevSample.isKeyframe
				{
					return prevIndex
				}
			}
			//	something has gone wrong
			//throw AppError("No previous keyframe")
			return 0
		}()
		let nextKeyframeIndex = try
		{
			for nextIndex in sampleIndex..<track.samples.count
			{
				let nextSample = track.samples[nextIndex]
				if nextSample.isKeyframe
				{
					return nextIndex
				}
			}
			//	something has gone wrong
			return track.samples.count-1
		}()
		
		//	now grab all the samples that have a decode time before this one
		let betweenKeyframeSamples = (prevKeyframeIndex...nextKeyframeIndex).map{ track.samples[$0] }
		let dependencies = betweenKeyframeSamples.filter{ $0.decodeTime <= thisSample.decodeTime }
		
		return Mp4SampleAndDependencies(sample: thisSample, dependences: dependencies)
	}
	
	public func AllocateTrackDecoder(track:TrackMeta) -> (any TrackDecoder)?
	{
		//	todo: specifically need to know its h264
		if case let .Video(codec) = track.encoding
		{
			func GetFrameSampleAndDependencies(presentationTime:Millisecond) async throws -> Mp4SampleAndDependencies
			{
				return try await self.GetFrameSampleAndDependencies(track: track, presentationTime: presentationTime,keyframe: false)
			}
			if let h264Codec = codec as? H264Codec
			{
				let decoder = VideoTrackDecoder<VideoToolboxDecoder<H264Codec,CGVideoFrame>>(codecMeta: h264Codec,getFrameSampleAndDependencies: GetFrameSampleAndDependencies,getFrameData: self.GetFrameData)
				return decoder
			}
			if let hevcCodec = codec as? HevcCodec
			{
				let decoder = VideoTrackDecoder<VideoToolboxDecoder<HevcCodec,CGVideoFrame>>(codecMeta: hevcCodec,getFrameSampleAndDependencies: GetFrameSampleAndDependencies,getFrameData: self.GetFrameData)
				return decoder
			}
		}
		
		return nil
	}
	
	public static func DetectIsFormat(headerData: Data) async -> Bool 
	{
		var reader = DataReader(data: headerData)
		do
		{
			try await reader.ReadEbmlDocumentMetaElement()
			return true
		}
		catch
		{
			print("Detecting mkv error; \(error.localizedDescription). Assuming not mkv")
			return false
		}
	}
}



extension EBMLElementID
{
	var fourcc : Fourcc
	{
		switch self
		{
			case .ebml:				return Fourcc("embl")
			case .ebmlVersion:		return Fourcc("embV")
			case .ebmlReadVersion:	return Fourcc("erdV")
			case .ebmlMaxIDLength:	return Fourcc("eLen")
			case .ebmlMaxSizeLength:	return Fourcc("eSiz")
				
			case .docType:			return Fourcc("docT")
			case .docTypeVersion:		return Fourcc("docV")
			case .docTypeReadVersion:	return Fourcc("docR")
				
			case .segment:			return Fourcc("Segm")
				
			case .info:				return Fourcc("Info")
			case .timestampScale:	return Fourcc("TSsc")
			case .title:			return Fourcc("Titl")

			case .tracks:			return Fourcc("Trks")
			case .trackEntry:		return Fourcc("Trak")
			case .trackNumber:		return Fourcc("Trk#")
			case .trackUID:			return Fourcc("Trk$")
			case .trackType:		return Fourcc("TrkT")
				
			case .name:				return Fourcc("Name")
			case .language:			return Fourcc("Lang")
			case .codecID:			return Fourcc("Cdc#")
			case .codecName:		return Fourcc("Cdec")
			case .codecPrivate:		return Fourcc("CdcD")

			case .Void:				return Fourcc("Void")
			case .video:			return Fourcc("Vido")
			
			case .audio:			return Fourcc("Audo")
				
			case .cluster:			return Fourcc("Clst")
			case .timestamp:		return Fourcc("Time")
			case .simpleBlock:		return Fourcc("blkS")
			case .blockGroup:		return Fourcc("blkG")
			case .referenceBlock:	return Fourcc("blkR")
			case .blockDuration:	return Fourcc("blkD")
			case .duration:			return Fourcc("Dura")
			default:				return Fourcc(self.rawValue)
		}
	}
}


import Foundation

// MARK: - EBML Element IDs
enum EBMLElementID: UInt32 {
	case ebml = 0x1A45DFA3
	case ebmlVersion = 0x4286
	case ebmlReadVersion = 0x42F7
	case ebmlMaxIDLength = 0x42F2
	case ebmlMaxSizeLength = 0x42F3
	case docType = 0x4282
	case docTypeVersion = 0x4287
	case docTypeReadVersion = 0x4285
	
	// Segment
	case segment = 0x18538067
	
	// Meta Seek
	case seekHead = 0x114D9B74
	case seek = 0x4DBB
	case seekID = 0x53AB
	case seekPosition = 0x53AC
	
	// Segment Info
	case info = 0x1549A966
	case timestampScale = 0x2AD7B1
	case muxingApp = 0x4D80
	case writingApp = 0x5741
	case duration = 0x4489
	case title = 0x7BA9
	
	// Tracks
	case tracks = 0x1654AE6B
	case trackEntry = 0xAE
	case trackNumber = 0xD7
	case trackUID = 0x73C5
	case trackType = 0x83
	case flagEnabled = 0xB9
	case flagDefault = 0x88
	case flagForced = 0x55AA
	case flagLacing = 0x9C
	case defaultDuration = 0x23E383
	case name = 0x536E
	case language = 0x22B59C
	case codecID = 0x86
	case codecName = 0x258688
	case codecPrivate = 0x63A2
	
	case Void = 0xec
	
	// Video
	case video = 0xE0
	case pixelWidth = 0xB0
	case pixelHeight = 0xBA
	case displayWidth = 0x54B0
	case displayHeight = 0x54BA
	
	// Audio
	case audio = 0xE1
	case samplingFrequency = 0xB5
	case channels = 0x9F
	case bitDepth = 0x6264
	
	// Cluster
	case cluster = 0x1F43B675
	case timestamp = 0xE7
	case simpleBlock = 0xA3
	case blockGroup = 0xA0
	case block = 0xA1
	case blockDuration = 0x9B
	case referenceBlock = 0xFB
}

// MARK: - EBML Element
//	this can turn into an atom
struct EBMLElement : Atom 
{
	let id : UInt32
	var type : EBMLElementID?	{	EBMLElementID(rawValue: id)	}
	var fourcc : Fourcc			{	type?.fourcc ?? Fourcc(id)	}
	let contentSize : UInt64
	let filePosition: UInt64
	let headerSize: UInt64
	var totalSize: UInt64		{	headerSize + contentSize	}
	
	@available(*, deprecated, renamed: "contentSize", message: "More specific name")
	var size : UInt64	{	contentSize	}
	
	/*
	//	eventually this whole EBMLelement will be an atom
	func GetAsAtomHeader() throws -> AtomHeader
	{
		return try AtomHeader(fourcc: fourcc, filePosition: filePosition, size: totalSize)
	}
*/
	//	atom conformity
	var childAtoms: [any Atom]? = nil

}


// MARK: - Track Types
enum MkvTrackType: UInt8 {
	case video = 1
	case audio = 2
	case complex = 3
	case logo = 16
	case subtitle = 17
	case buttons = 18
	case control = 32
}

// MARK: - Video Track Metadata
struct MkvVideoMeta {
	let pixelWidth: UInt64
	let pixelHeight: UInt64
	let displayWidth: UInt64?
	let displayHeight: UInt64?
	let codecPrivate: Data?  // Codec-specific initialization data (e.g., H.264 SPS/PPS)
}

// MARK: - Audio Track Metadata
struct MkvAudioMeta {
	let samplingFrequency: Double
	let channels: UInt64
	let bitDepth: UInt64?
	let codecPrivate: Data?  // Codec-specific initialization data
}

// MARK: - Text/Subtitle Track Metadata
struct MkvTextMeta {
	// Add subtitle-specific metadata as needed
}

// MARK: - Track Metadata (Typed Enum)
enum MkvTrackMetadata {
	case video(MkvVideoMeta)
	case audio(MkvAudioMeta)
	case text(MkvTextMeta)
	case other
}

// MARK: - Track Info
struct MkvTrackMeta 
{
	let number: UInt64
	let uid: UInt64
	let codecID: String
	let name: String?
	let language: String?
	let defaultDurationNano: UInt64?
	var defaultDuration: Millisecond?	{	defaultDurationNano.map{ $0 / 1_000_000 }	}
	let metadata: MkvTrackMetadata

	private var defaultDurationString : String	{	defaultDuration.map{ "\($0)ms" } ?? "null"	}
	
	func GetMetaAtoms(parent:any Atom) -> [InfoAtom]
	{
		[
			InfoAtom(info: "track number \(number)", parent: parent,uidOffset: 0),
			InfoAtom(info: "uid \(uid)", parent: parent,uidOffset: 1),
			InfoAtom(info: "codecID \(codecID)", parent: parent,uidOffset: 2),
			InfoAtom(info: "name \(name ?? "null")", parent: parent,uidOffset: 3),
			InfoAtom(info: "language \(language ?? "null")", parent: parent,uidOffset: 4),
			InfoAtom(info: "defaultDuration \(defaultDurationString)", parent: parent,uidOffset: 5)
		]
	}
}

// MARK: - Segment Info
struct SegmentInfo {
	let timestampScale: UInt64
	let duration: Double?
	let muxingApp: String?
	let writingApp: String?
	let title: String?
}

// MARK: - Sample/Frame Data
struct MkvSample {
	let trackNumber: UInt64
	let timestamp: Int64  // Presentation timestamp in milliseconds
	let decodeTimestamp: Int64  // Decode timestamp in milliseconds
	let isKeyframe: Bool
	let fileOffset: Int   // Offset in the file where sample data starts
	let size: Int         // Size of sample data in bytes
	var duration: UInt64? // In track time scale units
	
	/// Read the sample data from the original Data object
	func readData(from data: Data) -> Data? {
		guard fileOffset + size <= data.count else { return nil }
		return data[fileOffset..<fileOffset + size]
	}
}

// MARK: - Cluster
struct MkvCluster {
	let timestamp: UInt64
	let samples: [MkvSample]
	
	/// Returns samples sorted by decode timestamp for proper decoding
	func samplesByDecodeOrder() -> [MkvSample] {
		samples.sorted { $0.decodeTimestamp < $1.decodeTimestamp }
	}
}

// MARK: - MKV Document
struct MKVDocument 
{
	var meta : MkvDocumentMeta
	let segmentMeta : MkvAtom_SegmentInfo?
	let tracks: [MkvTrackMeta]
	let clusters: [MkvCluster]
	
	/// Returns all samples from all clusters sorted by decode order
	func allSamplesByDecodeOrder() -> [MkvSample] {
		clusters.flatMap { $0.samplesByDecodeOrder() }
	}
	
	/// Returns samples for a specific track sorted by decode order
	func samplesByDecodeOrder(forTrack trackNumber: UInt64) -> [MkvSample] {
		clusters
			.flatMap { $0.samplesByDecodeOrder() }
			.filter { $0.trackNumber == trackNumber }
	}
}

// MARK: - MKV Parser
class MKVParser {
	private let data: Data
	private var offset: Int = 0
	private var decodeTimestampCounters: [UInt64: Int64] = [:]  // Track number -> decode timestamp counter
	
	init(data: Data) {
		self.data = data
	}
	
	
	func ReadSegmentAtom(fileReader:inout DataReader,onAtom:(any Atom)->Void) async throws -> MkvAtom_Segment
	{
		//	annoyingly the segment is massive, so we dont want to read all the data at once
		let segmentHeader = try await fileReader.ReadEbmlElementHeader()
		guard segmentHeader.type == .segment else
		{
			throw PopCodecError("Expecting segment element but got \(segmentHeader.fourcc)")
		}
		onAtom(segmentHeader)

				
		//	these should all be atoms
		var segmentInfoAtom: MkvAtom_SegmentInfo?
		var tracks: [MkvTrackMeta] = []
		var clusters: [MkvCluster] = []
		
		var segmentContent = try await fileReader.GetReaderForBytes(byteCount: segmentHeader.contentSize)
			
		while segmentContent.bytesRemaining > 0
		{
			var element = try await segmentContent.ReadEbmlElementHeader()
			var children : [any Atom] = []
			
			self.offset = Int(element.contentFilePosition)
			var elementContent = try await segmentContent.GetReaderForBytes(byteCount: element.contentSize) as! DataReader
			
			switch element.type
			{
				case .info:
					segmentInfoAtom = try await MkvAtom_SegmentInfo.Decode(header: element, content: &elementContent)
					
				case .tracks:
					let parsedTracks = try parseTracks(size: element.contentSize, childElements: &children)
					tracks.append(contentsOf: parsedTracks)
					
				case .cluster:
					guard let segmentInfo = segmentInfoAtom?.segmentInfo else
					{
						throw PopCodecError("Cannot parse cluster without segment info")
					}
					//	speed up track lookup
					let trackMap = Dictionary(uniqueKeysWithValues: tracks.map{ ($0.number, $0) } )
					let cluster = try parseCluster(size: element.contentSize, segmentInfo: segmentInfo, tracks:trackMap,childElements:&children) 
					clusters.append(cluster)
					
				default:
					//try await segmentContent.SkipBytes(Int(element.contentSize))
					print("Unhandled element \(element.fourcc)")
			}
			
			//	leave .childAtoms null if possible
			if !children.isEmpty
			{
				element.childAtoms = children
			}
			onAtom(element)
		}
		
	
		let segment = MkvAtom_Segment(header: segmentHeader, segmentInfo: segmentInfoAtom, tracks: tracks, clusters: clusters)
		return segment
	}
	
	// MARK: - Public Parse Method
	func parse(fileReader:inout DataReader,onAtom:(any Atom)->Void) async throws -> MKVDocument 
	{
		let documentMetaAtom = try await fileReader.ReadEbmlDocumentMetaElement()
		onAtom(documentMetaAtom)
		
		let segmentAtom = try await ReadSegmentAtom(fileReader:&fileReader, onAtom:onAtom)
	
		return MKVDocument(meta:documentMetaAtom.documentMeta,
						   segmentMeta: segmentAtom.segmentInfo,
						   tracks: segmentAtom.tracks,
						   clusters: segmentAtom.clusters
		)
	}
	
	// MARK: - Element Reading
	private func readElement() throws -> EBMLElement {
		guard offset < data.count else {
			throw MKVError.endOfData
		}
		
		let startOffset = offset
		let id = try readElementID()
		let contentSize = try readVIntSize()
		let headerSize = offset - startOffset
		
		//	this data offset is the END...
		return EBMLElement(
			id: id,
			contentSize: contentSize,
			//	was previously writing the content start position
			filePosition: UInt64(startOffset), //UInt64(offset),
			headerSize: UInt64(headerSize)
		)
	}
	
	// MARK: - Element ID Reading (preserves the marker bit)
	private func readElementID() throws -> UInt32 {
		guard offset < data.count else {
			throw MKVError.endOfData
		}
		
		let firstByte = data[offset]
		var length = 0
		var mask: UInt8 = 0x80
		
		// Determine length by finding first set bit
		for i in 0..<8 {
			if (firstByte & mask) != 0 {
				length = i + 1
				break
			}
			mask >>= 1
		}
		
		guard length > 0 && length <= 4 else {
			throw MKVError.invalidElementID
		}
		
		// Read all bytes including the marker bit
		var value: UInt32 = UInt32(firstByte)
		offset += 1
		
		for _ in 1..<length {
			guard offset < data.count else {
				throw MKVError.endOfData
			}
			value = (value << 8) | UInt32(data[offset])
			offset += 1
		}
		
		return value
	}
	
	// MARK: - Variable-length Integer Reading (for sizes, strips marker bit)
	private func readVIntSize() throws -> UInt64 {
		guard offset < data.count else {
			throw MKVError.endOfData
		}
		
		let firstByte = data[offset]
		var length = 0
		var mask: UInt8 = 0x80
		
		for i in 0..<8 {
			if (firstByte & mask) != 0 {
				length = i + 1
				break
			}
			mask >>= 1
		}
		
		guard length > 0 else {
			throw MKVError.invalidVInt
		}
		
		// Strip the marker bit for size values
		var value: UInt64 = UInt64(firstByte & (mask - 1))
		offset += 1
		
		for _ in 1..<length {
			guard offset < data.count else {
				throw MKVError.endOfData
			}
			value = (value << 8) | UInt64(data[offset])
			offset += 1
		}
		
		return value
	}
	
	// MARK: - Data Type Reading
	private func readUInt(size: Int) throws -> UInt64 {
		guard offset + size <= data.count else {
			throw MKVError.endOfData
		}
		
		var value: UInt64 = 0
		for i in 0..<size {
			value = (value << 8) | UInt64(data[offset + i])
		}
		offset += size
		return value
	}
	
	private func readFloat(size: Int) throws -> Double {
		guard offset + size <= data.count else {
			throw MKVError.endOfData
		}
		
		if size == 4 {
			let bits = try readUInt(size: 4)
			return Double(Float(bitPattern: UInt32(bits)))
		} else if size == 8 {
			let bits = try readUInt(size: 8)
			return Double(bitPattern: bits)
		}
		
		throw MKVError.invalidFloatSize
	}
	
	private func readString(size: Int) throws -> String {
		guard offset + size <= data.count else {
			throw MKVError.endOfData
		}
		
		let stringData = data[offset..<offset + size]
		offset += size
		return String(data: stringData, encoding: .utf8) ?? ""
	}
	
	private func readData(size: Int) throws -> Data {
		guard offset + size <= data.count else {
			throw MKVError.endOfData
		}
		
		let result = data[offset..<offset + size]
		offset += size
		return Data(result)
	}
	
	
	// MARK: - Tracks Parsing
	private func parseTracks(size: UInt64,childElements:inout [any Atom]) throws -> [MkvTrackMeta] 
	{
		let endOffset = offset + Int(size)
		var tracks: [MkvTrackMeta] = []
		
		while offset < endOffset 
		{
			let elem = try readElement()
			childElements.append(elem)
			if EBMLElementID(rawValue: elem.id) == .trackEntry 
			{
				let track = try parseTrackEntry(size: Int(elem.size)) 
				tracks.append(track)
			}
			else 
			{
				offset += Int(elem.size)
			}
		}
		
		return tracks
	}
	
	private func parseTrackEntry(size: Int) throws -> MkvTrackMeta 
	{
		let endOffset = offset + size
		
		var number: UInt64 = 0
		var uid: UInt64 = 0
		var trackType: MkvTrackType = .video
		var codecID = ""
		var name: String?
		var language: String?
		var defaultDurationNano: UInt64?
		var codecPrivate: Data?
		var pixelWidth: UInt64?
		var pixelHeight: UInt64?
		var displayWidth: UInt64?
		var displayHeight: UInt64?
		var samplingFrequency: Double?
		var channels: UInt64?
		var bitDepth: UInt64?
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .trackNumber:
					number = try readUInt(size: Int(elem.size))
				case .trackUID:
					uid = try readUInt(size: Int(elem.size))
				case .trackType:
					let type = try readUInt(size: Int(elem.size))
					trackType = MkvTrackType(rawValue: UInt8(type)) ?? .video
				case .codecID:
					codecID = try readString(size: Int(elem.size))
				case .codecPrivate:
					codecPrivate = try readData(size: Int(elem.size))
				case .name:
					name = try readString(size: Int(elem.size))
				case .language:
					language = try readString(size: Int(elem.size))
				case .defaultDuration:
					defaultDurationNano = try readUInt(size: Int(elem.size))
				case .video:
					(pixelWidth, pixelHeight, displayWidth, displayHeight) = try parseVideo(size: Int(elem.size))
				case .audio:
					(samplingFrequency, channels, bitDepth) = try parseAudio(size: Int(elem.size))
				default:
					offset += Int(elem.size)
			}
		}
		
		// Build typed metadata based on track type
		let metadata: MkvTrackMetadata
		switch trackType {
			case .video:
				if let width = pixelWidth, let height = pixelHeight {
					metadata = .video(MkvVideoMeta(
						pixelWidth: width,
						pixelHeight: height,
						displayWidth: displayWidth,
						displayHeight: displayHeight,
						codecPrivate: codecPrivate
					))
				} else {
					metadata = .other
				}
			case .audio:
				if let freq = samplingFrequency, let ch = channels {
					metadata = .audio(MkvAudioMeta(
						samplingFrequency: freq,
						channels: ch,
						bitDepth: bitDepth,
						codecPrivate: codecPrivate
					))
				} else {
					metadata = .other
				}
			case .subtitle:
				metadata = .text(MkvTextMeta())
			default:
				metadata = .other
		}
		
		return MkvTrackMeta(
			number: number,
			uid: uid,
			codecID: codecID,
			name: name,
			language: language,
			defaultDurationNano: defaultDurationNano,
			metadata: metadata
		)
	}
	
	private func parseVideo(size: Int) throws -> (UInt64?, UInt64?, UInt64?, UInt64?) {
		let endOffset = offset + size
		
		var pixelWidth: UInt64?
		var pixelHeight: UInt64?
		var displayWidth: UInt64?
		var displayHeight: UInt64?
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .pixelWidth:
					pixelWidth = try readUInt(size: Int(elem.size))
				case .pixelHeight:
					pixelHeight = try readUInt(size: Int(elem.size))
				case .displayWidth:
					displayWidth = try readUInt(size: Int(elem.size))
				case .displayHeight:
					displayHeight = try readUInt(size: Int(elem.size))
				default:
					offset += Int(elem.size)
			}
		}
		
		return (pixelWidth, pixelHeight, displayWidth, displayHeight)
	}
	
	private func parseAudio(size: Int) throws -> (Double?, UInt64?, UInt64?) {
		let endOffset = offset + size
		
		var samplingFrequency: Double?
		var channels: UInt64?
		var bitDepth: UInt64?
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .samplingFrequency:
					samplingFrequency = try readFloat(size: Int(elem.size))
				case .channels:
					channels = try readUInt(size: Int(elem.size))
				case .bitDepth:
					bitDepth = try readUInt(size: Int(elem.size))
				default:
					offset += Int(elem.size)
			}
		}
		
		return (samplingFrequency, channels, bitDepth)
	}
	
	// MARK: - Cluster Parsing
	private func parseCluster(size: UInt64, segmentInfo: SegmentInfo?,tracks:[UInt64:MkvTrackMeta],childElements:inout [any Atom]) throws -> MkvCluster 
	{
		let endOffset = offset + Int(size)
		let timestampScale = segmentInfo?.timestampScale ?? 1_000_000
		
		var clusterTimestamp: UInt64 = 0
		var samples: [MkvSample] = []
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			childElements.append(elem)
			
			switch EBMLElementID(rawValue: elem.id) {
				case .timestamp:
					clusterTimestamp = try readUInt(size: Int(elem.size))
				case .simpleBlock:
					var sample = try parseSimpleBlock(
						size: Int(elem.size),
						clusterTimestamp: clusterTimestamp,
						timestampScale: timestampScale,
						trackMetas:tracks
					)
					samples.append(sample)

				case .blockGroup:
					let sample = try parseBlockGroup(
						size: Int(elem.size),
						clusterTimestamp: clusterTimestamp,
						timestampScale: timestampScale
					)
					if sample.duration == nil
					{
						print("Block sample missing duration")
					}
					samples.append(sample)
					
				default:
					print("Unknown element \(elem.fourcc) x\(elem.contentSize)")
					offset += Int(elem.size)
			}
		}
		
		return MkvCluster(timestamp: clusterTimestamp, samples: samples)
	}
	
	private func parseSimpleBlock(size: Int, clusterTimestamp: UInt64, timestampScale: UInt64,trackMetas:[UInt64:MkvTrackMeta]) throws -> MkvSample {
		let startOffset = offset
		let endOffset = offset + size
		
		// Read track number (variable-length)
		let trackNumber = try readVIntSize()
		
		// Read timestamp (2 bytes, signed)
		guard offset + 2 <= data.count else {
			throw MKVError.endOfData
		}
		let timestampBytes = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
		let relativeTimestamp = Int16(bitPattern: timestampBytes)
		offset += 2
		
		// Read flags
		guard offset < data.count else {
			throw MKVError.endOfData
		}
		let flags = data[offset]
		offset += 1
		
		let isKeyframe = (flags & 0x80) != 0
		
		// Calculate frame data location
		let frameDataOffset = offset
		let dataSize = endOffset - offset
		guard frameDataOffset + dataSize <= data.count else {
			throw MKVError.endOfData
		}
		
		// Skip over the data (don't copy it)
		offset += dataSize
		
		// Calculate absolute timestamp in milliseconds
		let absoluteTimestamp = Int64(clusterTimestamp) + Int64(relativeTimestamp)
		let timestampMs = (absoluteTimestamp * Int64(timestampScale)) / 1_000_000
		
		// Assign decode timestamp (in file order)
		let decodeTimestamp = assignDecodeTimestamp(trackNumber: trackNumber, timestampScale: Int64(timestampScale))

		//	read default duration
		var duration : UInt64? = nil
		if let trackMeta = trackMetas[trackNumber]
		{
			duration = trackMeta.defaultDuration
		}
		
		return MkvSample(
			trackNumber: trackNumber,
			timestamp: timestampMs,
			decodeTimestamp: decodeTimestamp,
			isKeyframe: isKeyframe,
			fileOffset: frameDataOffset,
			size: dataSize,
			duration: duration
		)
	}
	
	private func parseBlockGroup(size: Int, clusterTimestamp: UInt64, timestampScale: UInt64) throws -> MkvSample {
		let endOffset = offset + size
		
		var frameDataOffset: Int = 0
		var frameDataSize: Int = 0
		var trackNumber: UInt64 = 0
		var relativeTimestamp: Int16 = 0
		var isKeyframe = true
		var duration: UInt64?
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .block:
					let blockStartOffset = offset
					
					// Read track number
					trackNumber = try readVIntSize()
					
					// Read timestamp
					guard offset + 2 <= data.count else {
						throw MKVError.endOfData
					}
					let timestampBytes = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
					relativeTimestamp = Int16(bitPattern: timestampBytes)
					offset += 2
					
					// Read flags
					guard offset < data.count else {
						throw MKVError.endOfData
					}
					let flags = data[offset]
					offset += 1
					
					isKeyframe = (flags & 0x80) != 0
					
					// Calculate frame data location
					frameDataOffset = offset
					let remainingSize = Int(elem.size) - (offset - blockStartOffset)
					guard offset + remainingSize <= data.count else {
						throw MKVError.endOfData
					}
					
					frameDataSize = remainingSize
					offset += remainingSize
					
				case .blockDuration:
					duration = try readUInt(size: Int(elem.size))
					
				case .referenceBlock:
					isKeyframe = false
					offset += Int(elem.size)
					
				default:
					offset += Int(elem.size)
			}
		}
		
		guard frameDataSize > 0 else {
			throw MKVError.missingBlockData
		}
		
		// Calculate absolute timestamp in milliseconds
		let absoluteTimestamp = Int64(clusterTimestamp) + Int64(relativeTimestamp)
		let timestampMs = (absoluteTimestamp * Int64(timestampScale)) / 1_000_000
		
		// Assign decode timestamp (in file order)
		let decodeTimestamp = assignDecodeTimestamp(trackNumber: trackNumber, timestampScale: Int64(timestampScale))
		
		return MkvSample(
			trackNumber: trackNumber,
			timestamp: timestampMs,
			decodeTimestamp: decodeTimestamp,
			isKeyframe: isKeyframe,
			fileOffset: frameDataOffset,
			size: frameDataSize,
			duration: duration
		)
	}
	
	// MARK: - Decode Timestamp Assignment
	private func assignDecodeTimestamp(trackNumber: UInt64, timestampScale: Int64) -> Int64 {
		// Decode timestamp is based on file order, not presentation order
		// Each sample gets a sequential decode time based on when it appears in the file
		let currentCounter = decodeTimestampCounters[trackNumber] ?? 0
		decodeTimestampCounters[trackNumber] = currentCounter + 1
		
		// Convert counter to milliseconds using the timestamp scale
		// This creates sequential decode timestamps in the same units as presentation timestamps
		return (currentCounter * timestampScale) / 1_000_000
	}
}

// MARK: - Errors
enum MKVError: Error {
	case invalidEBMLHeader
	case invalidSegment
	case endOfData
	case invalidVInt
	case invalidFloatSize
	case invalidElementID
	case missingBlockData
}


extension ByteReader
{
	mutating func ReadEbmlDocumentMetaElement() async throws -> MkvAtom_Ebml
	{
		//	read first element and check it has the correct id
		let element = try await ReadEbmlElementHeader()
		if element.type != EBMLElementID.ebml
		{
			throw PopCodecError("First Ebml id is incorrect")
		}
		
		//	turn it into an atom
		let contentsFilePosition = self.globalPosition
		let contents = try await self.ReadBytes(Int(element.size))
		var contentsReader = DataReader(data: contents, globalStartPosition: Int(contentsFilePosition))
		let atom = try await MkvAtom_Ebml.Decode(header: element, content: &contentsReader)
		return atom
	}
	
	//	todo: rename this
	//	mkv
	mutating func readUInt(size: Int) async throws -> UInt64 
	{
		var value: UInt64 = 0
		for i in 0..<size 
		{
			let nextByte = try await self.Read8()
			value = (value << 8) | UInt64(nextByte)
		}
		return value
	}
	
	//	mkv
	mutating func readString(size: Int) async throws -> String 
	{
		let stringBytes = try await self.ReadBytes(size)
		guard let string = String(data: stringBytes, encoding: .utf8) else
		{
			throw PopCodecError("Failed to turn x\(stringBytes.count) bytes into string")
		}
		return string
	}
	
	mutating func readFloat(size: Int) async throws -> Double
	{
		if size == 4 
		{
			let bits = try await readUInt(size: 4)
			return Double(Float(bitPattern: UInt32(bits)))
		} 
		else if size == 8 
		{
			let bits = try await readUInt(size: 8)
			return Double(bitPattern: bits)
		}
		throw MKVError.invalidFloatSize
	}
	
}

struct MkvDocumentMeta
{
	var ebmlVersion: UInt64 = 1
	var docType = ""
	var docTypeVersion: UInt64 = 1
}

struct MkvAtom_Ebml : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.ebml.fourcc

	var header: any Atom
	var childAtoms: [any Atom]?
	//	really should just have this meta as atoms
	var documentMeta : MkvDocumentMeta
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var meta = MkvDocumentMeta()
		
		//	read all the child elements
		var children : [EBMLElement] = []
		while content.bytesRemaining > 0
		{
			let element = try await content.ReadEbmlElementHeader()
			
			//	these should be seperate atoms really
			switch element.type
			{
				case .ebmlVersion:
					meta.ebmlVersion = try await content.readUInt(size: Int(element.size))
				case .docType:
					meta.docType = try await content.readString(size: Int(element.size))
				case .docTypeVersion:
					meta.docTypeVersion = try await content.readUInt(size: Int(element.size))
				default:
					try await content.SkipBytes(Int(element.size))
			}
			
			children.append(element)
		}
		
		return Self(header: header, childAtoms: children, documentMeta: meta)
	}
}


struct MkvAtom_Segment : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.segment.fourcc
	
	var header: any Atom
	var childAtoms: [any Atom]?
	{
		([segmentInfo] + trackMetaAtoms).compactMap{$0}
	}
	var trackMetaAtoms : [any Atom]
	{
		tracks.enumerated().map
		{
			trackIndex,trackMeta in
			var trackInfo = InfoAtom(info: "Track", parent: self, uidOffset: trackIndex*10)
			trackInfo.childAtoms = trackMeta.GetMetaAtoms(parent: trackInfo)
			return trackInfo
		}
	}
	
	//	really should just have this meta as atoms
	var segmentInfo : MkvAtom_SegmentInfo?
	var tracks : [MkvTrackMeta]
	var clusters : [MkvCluster]
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		throw PopCodecError("todo")
	}
}


struct MkvAtom_SegmentInfo : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.info.fourcc
	
	var header: any Atom
	var childAtoms: [any Atom]?
	
	//	really should just have this meta as atoms
	var segmentInfo : SegmentInfo
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var children : [any Atom] = []
		var timestampScale : UInt64 = 1_000_000
		var duration : Double?
		var muxingApp : String?
		var writingApp : String?
		var title : String?
		
		while content.bytesRemaining > 0
		{
			let element = try await content.ReadEbmlElementHeader()
			children.append(element)
			//print("Segment info atom \(element.fourcc) x\(element.contentSize)")
			print("segment info \(element.fourcc) x\(element.contentSize) @\(element.filePosition)")
			
			switch element.type
			{
				case .timestampScale:
					timestampScale = try await content.readUInt(size: Int(element.contentSize))
				case .duration:
					duration = try await content.readFloat(size: Int(element.contentSize))
				case .muxingApp:
					muxingApp = try await content.readString(size: Int(element.contentSize))
				case .writingApp:
					writingApp = try await content.readString(size: Int(element.contentSize))
				case .title:
					title = try await content.readString(size: Int(element.contentSize))
				default:
					try await content.SkipBytes(Int(element.contentSize))
			}
		}
		
		let segmentInfo = SegmentInfo(
			timestampScale: timestampScale,
			duration: duration,
			muxingApp: muxingApp,
			writingApp: writingApp,
			title: title
		)
		return Self(header: header, childAtoms: children, segmentInfo: segmentInfo)
	}
}
