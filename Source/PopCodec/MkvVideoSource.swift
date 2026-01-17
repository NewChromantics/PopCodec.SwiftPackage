import Foundation


extension MkvTrackType
{
	var encoding : TrackEncoding
	{
		switch self
		{
			case .video:	return .Video(MissingCodec())
			case .audio:	return .Audio
			case .subtitle:	return .Text
			default:		return .Unknown
		}
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
	var readHeaderTask : Task<MkvHeader,Error>!	//	promise
	
	required public init(url:URL)
	{
		self.url = url
		
		readHeaderTask = Task(operation: ReadHeader)
	}
	
	func ReadHeader() async throws -> MkvHeader
	{
		var fileData = try Data(contentsOf:url, options: .alwaysMapped)
		var fileReader = DataReader(data: fileData)
		let parser = MKVParser(data: fileData)
		let doc = try parser.parse()
		
		let trackMetas = doc.tracks.map
		{
			track in
			let trackUid = "\(track.uid)"
			let duration = track.defaultDuration ?? 0 
			let encoding = track.type.encoding
			let samples : [Mp4Sample] = []
			
			// Get all samples from track 1
			let trackSamples = doc.clusters
				.flatMap { $0.samples }
				.filter { $0.trackNumber == 1 }
				.sorted { $0.timestamp < $1.timestamp }
				.map
			{
				mkvSample in
				mkvSample.
				return Mp4Sample(mdatOffset: <#T##UInt64#>, size: <#T##UInt32#>, decodeTime: <#T##UInt64#>, presentationTime: <#T##UInt64#>, duration: <#T##UInt64#>, isKeyframe: <#T##Bool#>)
			}
			
			return TrackMeta(id: trackUid, duration: duration, encoding: encoding, samples: samples)
		}
		let header = MkvHeader(atoms: [], tracks: trackMetas)
		
		return header
	}
	
	public func GetTrackMetas() async throws -> [TrackMeta] 
	{
		let header = try await readHeaderTask.value
		return header.tracks
	}
	
	public func GetAtoms() async throws -> [any Atom] 
	{
		let header = try await readHeaderTask.value
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
				let decoder = VideoTrackDecoder<VideoToolboxDecoder<H264Codec>>(codecMeta: h264Codec,getFrameSampleAndDependencies: GetFrameSampleAndDependencies,getFrameData: self.GetFrameData)
				return decoder
			}
			if let hevcCodec = codec as? HevcCodec
			{
				let decoder = VideoTrackDecoder<VideoToolboxDecoder<HevcCodec>>(codecMeta: hevcCodec,getFrameSampleAndDependencies: GetFrameSampleAndDependencies,getFrameData: self.GetFrameData)
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
			//	todo: reduce how much to read
			let mkv = MKVParser(data: headerData)
			let doc = try mkv.parse()
			return true
		}
		catch
		{
			print("Detecting mkv error; \(error.localizedDescription). Assuming not mkv")
			return false
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
struct EBMLElement {
	let id: UInt32
	let size: UInt64
	let dataOffset: Int
	let headerSize: Int
	
	var totalSize: Int {
		headerSize + Int(size)
	}
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

// MARK: - Track Info
struct MkvTrackMeta {
	let number: UInt64
	let uid: UInt64
	let type: MkvTrackType
	let codecID: String
	let name: String?
	let language: String?
	let defaultDuration: UInt64?
	
	// Video specific
	let pixelWidth: UInt64?
	let pixelHeight: UInt64?
	let displayWidth: UInt64?
	let displayHeight: UInt64?
	
	// Audio specific
	let samplingFrequency: Double?
	let channels: UInt64?
	let bitDepth: UInt64?
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
	let timestamp: Int64  // In nanoseconds
	let isKeyframe: Bool
	let data: Data
	let duration: UInt64? // In track time scale units
}

// MARK: - Cluster
struct MkvCluster {
	let timestamp: UInt64
	let samples: [MkvSample]
}

// MARK: - MKV Document
struct MKVDocument {
	let ebmlVersion: UInt64
	let docType: String
	let docTypeVersion: UInt64
	let segmentInfo: SegmentInfo?
	let tracks: [MkvTrackMeta]
	let clusters: [MkvCluster]
}

// MARK: - MKV Parser
class MKVParser {
	private let data: Data
	private var offset: Int = 0
	private var segmentDataOffset: Int = 0  // Track where segment data starts
	
	init(data: Data) {
		self.data = data
	}
	
	// MARK: - Public Parse Method
	func parse() throws -> MKVDocument {
		offset = 0
		
		// Parse EBML header
		guard let ebmlElement = try? readElement(),
			  ebmlElement.id == EBMLElementID.ebml.rawValue else {
			throw MKVError.invalidEBMLHeader
		}
		
		var ebmlVersion: UInt64 = 1
		var docType = ""
		var docTypeVersion: UInt64 = 1
		
		let ebmlEnd = offset + Int(ebmlElement.size)
		while offset < ebmlEnd {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .ebmlVersion:
					ebmlVersion = try readUInt(size: Int(elem.size))
				case .docType:
					docType = try readString(size: Int(elem.size))
				case .docTypeVersion:
					docTypeVersion = try readUInt(size: Int(elem.size))
				default:
					offset += Int(elem.size)
			}
		}
		
		// Parse Segment
		guard let segmentElement = try? readElement(),
			  segmentElement.id == EBMLElementID.segment.rawValue else {
			throw MKVError.invalidSegment
		}
		
		segmentDataOffset = offset  // Remember where segment data starts
		
		var segmentInfo: SegmentInfo?
		var tracks: [MkvTrackMeta] = []
		var clusters: [MkvCluster] = []
		
		let segmentEnd = offset + Int(segmentElement.size)
		while offset < segmentEnd && offset < data.count {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .info:
					segmentInfo = try parseSegmentInfo(size: Int(elem.size))
				case .tracks:
					tracks = try parseTracks(size: Int(elem.size))
				case .cluster:
					if let cluster = try? parseCluster(size: Int(elem.size), segmentInfo: segmentInfo) {
						clusters.append(cluster)
					}
				default:
					offset += Int(elem.size)
			}
		}
		
		return MKVDocument(
			ebmlVersion: ebmlVersion,
			docType: docType,
			docTypeVersion: docTypeVersion,
			segmentInfo: segmentInfo,
			tracks: tracks,
			clusters: clusters
		)
	}
	
	// MARK: - Element Reading
	private func readElement() throws -> EBMLElement {
		guard offset < data.count else {
			throw MKVError.endOfData
		}
		
		let startOffset = offset
		let id = try readElementID()
		let size = try readVIntSize()
		let headerSize = offset - startOffset
		
		return EBMLElement(
			id: id,
			size: size,
			dataOffset: offset,
			headerSize: headerSize
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
	
	// MARK: - Segment Info Parsing
	private func parseSegmentInfo(size: Int) throws -> SegmentInfo {
		let endOffset = offset + size
		
		var timestampScale: UInt64 = 1_000_000
		var duration: Double?
		var muxingApp: String?
		var writingApp: String?
		var title: String?
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .timestampScale:
					timestampScale = try readUInt(size: Int(elem.size))
				case .duration:
					duration = try readFloat(size: Int(elem.size))
				case .muxingApp:
					muxingApp = try readString(size: Int(elem.size))
				case .writingApp:
					writingApp = try readString(size: Int(elem.size))
				case .title:
					title = try readString(size: Int(elem.size))
				default:
					offset += Int(elem.size)
			}
		}
		
		return SegmentInfo(
			timestampScale: timestampScale,
			duration: duration,
			muxingApp: muxingApp,
			writingApp: writingApp,
			title: title
		)
	}
	
	// MARK: - Tracks Parsing
	private func parseTracks(size: Int) throws -> [MkvTrackMeta] {
		let endOffset = offset + size
		var tracks: [MkvTrackMeta] = []
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			if EBMLElementID(rawValue: elem.id) == .trackEntry {
				if let track = try? parseTrackEntry(size: Int(elem.size)) {
					tracks.append(track)
				}
			} else {
				offset += Int(elem.size)
			}
		}
		
		return tracks
	}
	
	private func parseTrackEntry(size: Int) throws -> MkvTrackMeta {
		let endOffset = offset + size
		
		var number: UInt64 = 0
		var uid: UInt64 = 0
		var trackType: MkvTrackType = .video
		var codecID = ""
		var name: String?
		var language: String?
		var defaultDuration: UInt64?
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
				case .name:
					name = try readString(size: Int(elem.size))
				case .language:
					language = try readString(size: Int(elem.size))
				case .defaultDuration:
					defaultDuration = try readUInt(size: Int(elem.size))
				case .video:
					(pixelWidth, pixelHeight, displayWidth, displayHeight) = try parseVideo(size: Int(elem.size))
				case .audio:
					(samplingFrequency, channels, bitDepth) = try parseAudio(size: Int(elem.size))
				default:
					offset += Int(elem.size)
			}
		}
		
		return MkvTrackMeta(
			number: number,
			uid: uid,
			type: trackType,
			codecID: codecID,
			name: name,
			language: language,
			defaultDuration: defaultDuration,
			pixelWidth: pixelWidth,
			pixelHeight: pixelHeight,
			displayWidth: displayWidth,
			displayHeight: displayHeight,
			samplingFrequency: samplingFrequency,
			channels: channels,
			bitDepth: bitDepth
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
	private func parseCluster(size: Int, segmentInfo: SegmentInfo?) throws -> MkvCluster {
		let endOffset = offset + size
		let timestampScale = segmentInfo?.timestampScale ?? 1_000_000
		
		var clusterTimestamp: UInt64 = 0
		var samples: [MkvSample] = []
		
		while offset < endOffset {
			guard let elem = try? readElement() else { break }
			
			switch EBMLElementID(rawValue: elem.id) {
				case .timestamp:
					clusterTimestamp = try readUInt(size: Int(elem.size))
				case .simpleBlock:
					if let sample = try? parseSimpleBlock(
						size: Int(elem.size),
						clusterTimestamp: clusterTimestamp,
						timestampScale: timestampScale
					) {
						samples.append(sample)
					}
				case .blockGroup:
					if let sample = try? parseBlockGroup(
						size: Int(elem.size),
						clusterTimestamp: clusterTimestamp,
						timestampScale: timestampScale
					) {
						samples.append(sample)
					}
				default:
					offset += Int(elem.size)
			}
		}
		
		return MkvCluster(timestamp: clusterTimestamp, samples: samples)
	}
	
	private func parseSimpleBlock(size: Int, clusterTimestamp: UInt64, timestampScale: UInt64) throws -> MkvSample {
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
		
		// Read frame data
		let dataSize = endOffset - offset
		guard offset + dataSize <= data.count else {
			throw MKVError.endOfData
		}
		
		let frameData = data[offset..<offset + dataSize]
		offset += dataSize
		
		// Calculate absolute timestamp in nanoseconds
		let absoluteTimestamp = Int64(clusterTimestamp) + Int64(relativeTimestamp)
		let timestampNs = absoluteTimestamp * Int64(timestampScale)
		
		return MkvSample(
			trackNumber: trackNumber,
			timestamp: timestampNs,
			isKeyframe: isKeyframe,
			data: Data(frameData),
			duration: nil
		)
	}
	
	private func parseBlockGroup(size: Int, clusterTimestamp: UInt64, timestampScale: UInt64) throws -> MkvSample {
		let endOffset = offset + size
		
		var blockData: Data?
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
					
					// Read frame data
					let remainingSize = Int(elem.size) - (offset - blockStartOffset)
					guard offset + remainingSize <= data.count else {
						throw MKVError.endOfData
					}
					
					blockData = data[offset..<offset + remainingSize]
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
		
		guard let frameData = blockData else {
			throw MKVError.missingBlockData
		}
		
		// Calculate absolute timestamp in nanoseconds
		let absoluteTimestamp = Int64(clusterTimestamp) + Int64(relativeTimestamp)
		let timestampNs = absoluteTimestamp * Int64(timestampScale)
		
		return MkvSample(
			trackNumber: trackNumber,
			timestamp: timestampNs,
			isKeyframe: isKeyframe,
			data: frameData,
			duration: duration
		)
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

// MARK: - Usage Example
/*
 // Load MKV file
 let url = URL(fileURLWithPath: "video.mkv")
 let data = try Data(contentsOf: url)
 
 // Parse
 let parser = MKVParser(data: data)
 let document = try parser.parse()
 
 // Access information
 print("Document Type: \(document.docType)")
 print("EBML Version: \(document.ebmlVersion)")
 
 if let info = document.segmentInfo {
 print("Duration: \(info.duration ?? 0) seconds")
 print("Muxing App: \(info.muxingApp ?? "Unknown")")
 }
 
 for track in document.tracks {
 print("\nTrack #\(track.number)")
 print("Type: \(track.type)")
 print("Codec: \(track.codecID)")
 
 if track.type == .video {
 print("Resolution: \(track.pixelWidth ?? 0)x\(track.pixelHeight ?? 0)")
 } else if track.type == .audio {
 print("Sample Rate: \(track.samplingFrequency ?? 0) Hz")
 print("Channels: \(track.channels ?? 0)")
 }
 }
 
 // Read samples from clusters
 print("\nTotal clusters: \(document.clusters.count)")
 
 for (index, cluster) in document.clusters.enumerated() {
 print("\nCluster \(index)")
 print("Cluster timestamp: \(cluster.timestamp)")
 print("Samples in cluster: \(cluster.samples.count)")
 
 for sample in cluster.samples {
 print("  Track: \(sample.trackNumber), " +
 "Timestamp: \(sample.timestamp) ns, " +
 "Keyframe: \(sample.isKeyframe), " +
 "Size: \(sample.data.count) bytes")
 }
 }
 
 // Extract samples for a specific track (e.g., track #1)
 let trackSamples = document.clusters
 .flatMap { $0.samples }
 .filter { $0.trackNumber == 1 }
 .sorted { $0.timestamp < $1.timestamp }
 
 print("\nTrack 1 has \(trackSamples.count) samples")
 
 // Get first keyframe
 if let firstKeyframe = trackSamples.first(where: { $0.isKeyframe }) {
 print("First keyframe at: \(firstKeyframe.timestamp) ns")
 print("Keyframe data: \(firstKeyframe.data.count) bytes")
 }
 */
