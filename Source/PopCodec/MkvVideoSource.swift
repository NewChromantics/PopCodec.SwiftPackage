import Foundation
import Combine
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


extension MkvAtom_TrackMeta
{
	func GetEncoding() async -> TrackEncoding
	{
		switch self.trackType
		{
			case .audio:	
				return .Audio
				
			case .subtitle:	
				return .Text
				
			case .video:
				let codec = try? await GetVideoCodec(codecData: codecPrivate)
				return .Video(codec ?? MissingCodec())
				
			default:		
				return .Unknown
		}
	}
	
	func GetVideoCodec(codecData:Data?) async throws -> any Codec
	{
		guard let codecData else
		{
			throw DataNotFound("Missing codec data for \(codecId)")
		}
		let hevcId = "V_MPEGH/ISO/HEVC"
		let h264Id = "V_MPEG4/ISO/AVC"
		if codecId == h264Id
		{
			//	data is avcc atom
			let dummyAtomHeader = try AtomHeader(fourcc: Atom_avcc.fourcc, filePosition: 0, size: UInt32(codecData.count), size64: nil )
			var dataReader = DataReader(data: codecData)
			let atom = try await Atom_avcc.Decode(header: dummyAtomHeader, content: &dataReader)
			return atom.codec
		}
		
		if codecId == hevcId
		{
			//	data is avcc atom
			let dummyAtomHeader = try AtomHeader(fourcc: Atom_hvcc.fourcc, filePosition: 0, size: UInt32(codecData.count), size64: nil)
			var dataReader = DataReader(data: codecData)
			let atom = try await Atom_hvcc.Decode(header: dummyAtomHeader, content: &dataReader)
			return atom.codec
		}
		
		throw PopCodecError("Unknown video codec \(codecId)")
	}
}




public class MkvVideoSource : VideoSource, ObservableObject, PublisherPublisher
{
	public var publisherPublisherObservers: [AnyCancellable] = []
	
	public var typeName: String	{"Matroska"}
	
	var url : URL
	@Published public var atoms: [any Atom] = []
	@Published public var tracks: [TrackMeta] = []
	private var trackAtomCache : [MkvAtom_TrackMeta] = []
	private var trackNumberToTrackUid : [UInt64:TrackUid] = [:]
	@Published var trackSamples : [TrackUid:Mp4TrackSampleManager] = [:]
	
	//	we parse the whole file as its a chunked format 
	var parseFileTask : Task<Void,Error>!
	@Published var trackSampleKeyframePublishTrigger : Int = 0
	
	required public init(url:URL)
	{
		self.url = url
		
		parseFileTask = Task(operation: ParseFile)
	}

	
	public func WatchAtoms(onAtomsChanged:@escaping([any Atom])->Void) 
	{
		self.watch(&_atoms)
		{
			onAtomsChanged(self.atoms)
		}
	}
	
	public func WatchTracks(onTracksChanged:@escaping([TrackMeta])->Void) 
	{
		self.watch(&_tracks)
		{
			onTracksChanged(self.tracks)
		}
	}
	
	public func WatchTrackSampleKeyframes(onTrackSampleKeyframesChanged: @escaping (TrackUid) -> Void) 
	{
		//	todo: smarter version!
		self.watch(&_trackSampleKeyframePublishTrigger)
		{
			for track in self.tracks
			{
				onTrackSampleKeyframesChanged(track.id)
			}
		}
	}
	
	func OnTrackKeyframesChanged(track:TrackUid)
	{
		trackSampleKeyframePublishTrigger += 1
	}
	
	func OnFoundSamples(track:TrackUid,samples:[Mp4Sample]) async
	{
		let anyKeyframes = samples.contains{ $0.isKeyframe }
		
		var sampleManager = self.trackSamples[track] ?? Mp4TrackSampleManager()

		await sampleManager.AddSamples(samples: samples)
		self.trackSamples[track] = sampleManager
		//print("track \(track) now has \(self.trackSamples[track]!.samples.count) samples")
		
		if anyKeyframes
		{
			OnTrackKeyframesChanged(track:track)
		}
		
		self.objectWillChange.send()
	}
	
	func OnFoundAtom(atom:any Atom) async
	{
		self.atoms.append(atom)
		
		let segmentInfoAtom : MkvAtom_SegmentInfo? = try? atoms.GetFirstChildAtomAs(fourcc: MkvAtom_SegmentInfo.fourcc)
		
		var newTrackAtoms : [MkvAtom_TrackMeta] = []
		[atom].EnumerateAtoms(fourcc:MkvAtom_TrackMeta.fourcc)
		{
			atom in
			if let track = atom as? MkvAtom_TrackMeta
			{
				newTrackAtoms.append(track)
			}
			return true
		}
		trackAtomCache.append(contentsOf: newTrackAtoms)
		
		//	save new tracks
		for trackAtom in newTrackAtoms
		{
			let encoding = await trackAtom.GetEncoding()
			let startTime : Millisecond? = nil
			let duration = segmentInfoAtom?.segmentInfo.duration
			let trackMeta = TrackMeta(id: trackAtom.trackUid, startTime: startTime, duration: duration, encoding: encoding)
			self.trackNumberToTrackUid[trackAtom.number] = trackMeta.id
			self.tracks.append(trackMeta)
			self.trackSamples[trackMeta.id] = Mp4TrackSampleManager()
		}
		
		//	new atoms
		//print("new atom \(atom.fourcc)")
		
		//	new samples in a cluster
		if let cluster = atom as? MkvAtom_Cluster
		{
			//let allTrackMetaAtoms : [MkvAtom_TrackMeta] = self.atoms.EnumerateAtomsOf()
			let allTrackMetaAtoms = trackAtomCache
			
			for trackNumber in cluster.samplesPerTrackNumberInDecodeOrder.keys
			{
				let samples = cluster.samplesPerTrackNumberInDecodeOrder[trackNumber]!
				do
				{
					guard let trackUid = self.trackNumberToTrackUid[trackNumber] else
					{
						throw PopCodecError("Cannot find track uid for track number \(trackNumber)")
					}
					guard let trackAtom = allTrackMetaAtoms.first(where: {$0.number == trackNumber} ) else
					{
						throw PopCodecError("Missing atom for track number \(trackNumber)")
					}
					
					//	todo: we need the cluster to know which segment it came from
					let segmentTimescale = segmentInfoAtom?.segmentInfo.timestampScale ?? 1_000_000
					let clusterStartTimeUnscaled = (cluster.clusterTimestampUnscaled ?? 0)
					
					let sampleDuration = trackAtom.defaultDuration ?? 1

					//print("Cluster start \(cluster.clusterTimestampUnscaled ?? 0)")
					
					//	todo: store clusters into a more dynamic TrackSampleManager
					//	convert samples
					let mp4Samples = samples.enumerated().map
					{
						sampleIndexInTrackInCluster,mkvSample in
						var decodeTimeUnscaled : UInt64 = UInt64(sampleIndexInTrackInCluster) * sampleDuration
						decodeTimeUnscaled += clusterStartTimeUnscaled
						
						var presentationTimeUnscaled = Int64(clusterStartTimeUnscaled) + Int64(mkvSample.relativeTimestampUnscaled)
						
						let decodeTime = decodeTimeUnscaled * segmentTimescale / 1_000_000
						let presentationTime = UInt64( presentationTimeUnscaled * Int64(segmentTimescale) / 1_000_000 )
						//print("decodeTime \(decodeTime) + presentationTime \(presentationTime) ... diff \(Int(presentationTime)-Int(decodeTime))")
						
						let isKeyframe = mkvSample.isKeyframe
						
						//	this cant be right
						//let duration = segmentTimescale
						let duration = sampleDuration
						
						if presentationTime < 0
						{
							print("negative presentation time \(presentationTime)")
						}
						
						return Mp4Sample(mdatOffset: mkvSample.sampleDataFilePosition, size: UInt32(mkvSample.sampleDataSize), decodeTime: decodeTime, presentationTime: presentationTime, duration: duration, isKeyframe: isKeyframe)
					}
					await OnFoundSamples(track: trackUid, samples: mp4Samples)
				}
				catch
				{
					//	nowhere to store this error!
					print("Error adding cluster samples; \(error.localizedDescription)")
				}
			}
		}
		
		/*
		var atoms : [any Atom] = []
		var segmentAtom : MkvAtom_Segment?
		
		try await parser.parse(fileReader: &fileReader)
		{
			atom in
			print("Got atom \(atoms.count); \(atom.fourcc)")
			atoms.append(atom)
			
			if let seg = atom as? MkvAtom_Segment
			{
				segmentAtom = seg

				if !seg.tracks.isEmpty
				{
					let trackMetas = await try? Self.TrackAtomsToTrackMetas(seg.tracks, segmentAtom: seg)
					if let trackMetas
					{
						firstTracksPromise.Resolve(trackMetas)
					}
				}
			}
			
		}		
		
		guard let segmentAtom else
		{
			throw PopCodecError("No segment atom found")
		}
		var trackAtoms : [MkvAtom_TrackMeta] = segmentAtom.tracks
		guard !trackAtoms.isEmpty else
		{
			throw PopCodecError("No track atoms")
		}
		
		var clusterAtoms = segmentAtom.clusters
		
		let trackMetas = try await Self.TrackAtomsToTrackMetas(trackAtoms, segmentAtom: segmentAtom)
		firstTracksPromise.Resolve(trackMetas)
		
		
		let header = MkvHeader(atoms: atoms, tracks: trackMetas)
		
		//	read samples
		//	todo: change this to "add cluster" to then read the samples as we go
		if true
		{
			/*
			 let allSamples = clusterAtoms.flatMap
			 {
			 cluster in
			 return cluster.samplesPerTrackNumberInDecodeOrder
			 }
			 
			 //	store some stuff for quick access
			 //	[tracknumber] =
			 struct TrackSampleStuff
			 {
			 var samples : [Mp4Sample]
			 var defaultDuration : Millisecond?
			 
			 mutating func AddSample(_ sample:Mp4Sample)
			 {
			 self.samples.append(sample)
			 //self.samples.sort{ a,b in a.presentationTime < b.presentationTime }
			 }
			 }
			 var trackSamples : [UInt64:TrackSampleStuff] = [:]
			 
			 //	init
			 for trackAtom in trackAtoms
			 {
			 trackSamples[trackAtom.number] = TrackSampleStuff(samples: [],defaultDuration: trackAtom.defaultDuration)
			 }
			 
			 
			 //let trackSamples = allSamples.filter{ $0.trackNumber == track.number }
			 try allSamples.forEach
			 {
			 mkvSample in
			 let filePosition = mkvSample.filePosition
			 let size = UInt32(mkvSample.size)
			 let presentationTime = Millisecond(mkvSample.presentationTime)
			 guard var samplesForTrack = trackSamples[mkvSample.trackNumber] else
			 {
			 throw PopCodecError("Track missing for \(mkvSample.trackNumber)")
			 }
			 let sampleIndexInTrack = samplesForTrack.samples.count
			 let calculatedDecodeTime = mkvSample.GetDecodeTimeStamp(sampleIndexInTrack: UInt64(sampleIndexInTrack))
			 //	gr: not sure this is right? presentation time I dont think exists without decode time?
			 //		and presentation time comes from decode time (offset in cluster * sample duration)
			 let decodeTime = Millisecond(mkvSample.decodeTimestamp) ?? presentationTime
			 //	todo: fix this unscaled duration
			 let duration = mkvSample.durationUnscaled ?? samplesForTrack.defaultDuration ?? 1
			 let mp4Sample = Mp4Sample(mdatOffset: filePosition, size: size, decodeTime: decodeTime, presentationTime: presentationTime, duration: duration, isKeyframe: mkvSample.isKeyframe)
			 
			 samplesForTrack.AddSample(mp4Sample)
			 trackSamples[mkvSample.trackNumber] = samplesForTrack
			 if samplesForTrack.samples.count % 1000 == 0
			 {
			 print("track \(mkvSample.trackNumber) got to \(samplesForTrack.samples.count) samples...")
			 }
			 }
			 
			 //	save
			 for (trackNumber,sampleStuff) in trackSamples
			 {
			 let atom = trackAtoms.first{ $0.number == trackNumber }
			 guard let atom else
			 {
			 throw PopCodecError("atom for track number \(trackNumber) gone missing")
			 }
			 if self.trackSamples.index(forKey: atom.trackUid) == nil
			 {
			 self.trackSamples[atom.trackUid] = Mp4TrackSampleManager(samples:[])
			 }
			 let samples = sampleStuff.samples.sorted{ a,b in a.presentationTime < b.presentationTime }
			 self.trackSamples[atom.trackUid]!.samples = samples
			 }
			 */
		}
		
		*/
	}
	
	func ParseFile() async throws
	{
		var fileData = try Data(contentsOf:url, options: .alwaysMapped)
		var fileReader = DataReader(data: fileData)

		//	read first root element
		let documentMeta = try await fileReader.ReadEbmlDocumentMetaElement()
		await OnFoundAtom(atom: documentMeta)
		
		//	read segments (need example file with more than one!)
		while fileReader.bytesRemaining > 0
		{
			try await ReadSegmentAtom(fileReader: &fileReader)
			{
				await OnFoundAtom(atom:$0)
			}
		}
		
	}
	
	public func GetTrackSampleManager(track: TrackUid) throws -> TrackSampleManager 
	{
		let samples = self.trackSamples[track]
		guard let samples else
		{
			throw PopCodecError("No sample manager for \(track)")
		}
		return samples
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
		let track = try GetTrackSampleManager(track: frame.track)
		return try await GetFrameSample(track: track, presentationTime: frame.time, keyframe:keyframe)
	}
	
	func GetFrameSample(track:TrackSampleManager,presentationTime:Millisecond,keyframe:Bool) async throws -> Mp4Sample
	{
		guard let sample = track.GetSampleLessOrEqualToTime(presentationTime, keyframe: keyframe) else
		{
			throw DataNotFound("No such sample close to \(presentationTime)")
		}
		return sample
	}
	
	func GetFrameSampleAndDependencies(track:TrackSampleManager,presentationTime:Millisecond,keyframe:Bool) async throws -> Mp4SampleAndDependencies
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
				let trackSampleManager = try GetTrackSampleManager(track: track.id)
				return try await self.GetFrameSampleAndDependencies(track: trackSampleManager, presentationTime: presentationTime,keyframe: false)
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
struct MkvVideoMeta 
{
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


// MARK: - Segment Info
struct SegmentInfo {
	let timestampScale: UInt64?	//	X to nano - defaults to 1_000_000
	let durationMillisecondFloat : Double?
	var duration : Millisecond?	{	durationMillisecondFloat.map{ Millisecond($0) }	}
	let muxingApp: String?
	let writingApp: String?
	let title: String?
	var otherAtoms : [any Atom]
	
	private func GetMetaAtoms(parent:any Atom) -> [(any Atom)?]
	{
		return [
			timestampScale.map{ InfoAtom(info: "Timescale x\($0)", parent: parent, uidOffset: 0 ) },
			duration.map{ InfoAtom(info: "duration \($0)", parent: parent, uidOffset: 1 ) },
			muxingApp.map{ InfoAtom(info: "muxingApp \"\($0)\"", parent: parent, uidOffset: 2 ) },
			writingApp.map{ InfoAtom(info: "writingApp \"\($0)\"", parent: parent, uidOffset: 3 ) },
			title.map{ InfoAtom(info: "title \"\($0)\"", parent: parent, uidOffset: 4 ) },
		]
	}
	
	func GetAtoms(parent:any Atom) -> [any Atom]
	{
		GetMetaAtoms(parent: parent).compactMap{$0} + otherAtoms
	}
}

// MARK: - Sample/Frame Data
struct MkvSample 
{
	let trackNumber: UInt64
	
	let segmentTimestampScale : UInt64?
	var timestampScale : UInt64			{	segmentTimestampScale ?? 1_000_000	}
	let presentationTimeInClusterUnscaled : Int16
	let clusterPresentationTimeUnscaled : UInt64
	let decodeTimestamp: Int64  // Decode timestamp in milliseconds
	
	var presentationTimeNanos : Int64	{	(Int64(clusterPresentationTimeUnscaled) + Int64(presentationTimeInClusterUnscaled) ) * Int64(timestampScale)	}
	var presentationTime : Millisecond	{	Millisecond( presentationTimeNanos / 1_000_000 )	}
	
	var timestamp: Millisecond  {	presentationTime	}
	let isKeyframe: Bool
	let filePosition : UInt64
	let size : UInt64
	var durationUnscaled : UInt64? // In track time scale units
	
	func GetDecodeTimeStamp(sampleIndexInTrack:UInt64) -> Millisecond
	{
		let segmentTimescale = timestampScale
		let nanos = sampleIndexInTrack * segmentTimescale
		let ms = nanos / 1_000_000
		return ms
	}
	/*
	/// Read the sample data from the original Data object
	func readData(from data: Data) -> Data? {
		guard filePosition + size <= data.count else { return nil }
		return data[fileOffset..<fileOffset + size]
	}*/
}


func ReadSegmentAtom(fileReader:inout DataReader,onAtom:(any Atom)async->Void) async throws -> MkvAtom_Segment
{
	//	annoyingly the segment is massive, so we dont want to read all the data at once
	let segmentHeader = try await fileReader.ReadEbmlElementHeader()
	guard segmentHeader.type == .segment else
	{
		throw PopCodecError("Expecting segment element but got \(segmentHeader.fourcc)")
	}
	//onAtom(segmentHeader)

			
	//	these should all be atoms
	var segmentInfoAtom: MkvAtom_SegmentInfo?
	var trackListAtoms : [MkvAtom_TrackList] = []
	var clusters: [MkvAtom_Cluster] = []
	
	var segmentContent = try await fileReader.GetReaderForBytes(byteCount: segmentHeader.contentSize)
		
	while segmentContent.bytesRemaining > 0
	{
		var element = try await segmentContent.ReadEbmlElementHeader()
		
		var elementContent = try await segmentContent.GetReaderForBytes(byteCount: element.contentSize) as! DataReader
		
		switch element.type
		{
			case .info:
				let atom = try await MkvAtom_SegmentInfo.Decode(header: element, content: &elementContent)
				segmentInfoAtom = atom
				await onAtom(atom)
				
			case .tracks:
				let trackListAtom = try await MkvAtom_TrackList.Decode(header: element, content: &elementContent)
				trackListAtoms.append(trackListAtom)
				await onAtom(trackListAtom)
				
			case .cluster:
				let clusterAtom = try await MkvAtom_Cluster.Decode(header:element, content:&elementContent)
				clusters.append(clusterAtom)
				await onAtom(clusterAtom)
				
			default:
				print("Unhandled element \(element.fourcc)")
				await onAtom(element)
		}
		
		
	}
	

	let segment = MkvAtom_Segment(header: segmentHeader, segmentInfo: segmentInfoAtom, trackLists: trackListAtoms, clusters: clusters)
	return segment
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
		let contents = try await self.ReadBytes(element.contentSize)
		var contentsReader = DataReader(data: contents, globalStartPosition: contentsFilePosition)
		let atom = try await MkvAtom_Ebml.Decode(header: element, content: &contentsReader)
		return atom
	}
	
	//	todo: rename this
	//	mkv
	mutating func readUInt(size: UInt64) async throws -> UInt64 
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
	mutating func readString(size: UInt64) async throws -> String 
	{
		let stringBytes = try await self.ReadBytes(size)
		guard let string = String(data: stringBytes, encoding: .utf8) else
		{
			throw PopCodecError("Failed to turn x\(stringBytes.count) bytes into string")
		}
		return string
	}
	
	mutating func readFloat(size: UInt64) async throws -> Double
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
					meta.ebmlVersion = try await content.readUInt(size: element.contentSize)
				case .docType:
					meta.docType = try await content.readString(size: element.contentSize)
				case .docTypeVersion:
					meta.docTypeVersion = try await content.readUInt(size: element.contentSize)
				default:
					try await content.SkipBytes(element.contentSize)
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
		([segmentInfo] + trackLists).compactMap{$0}
	}

	//	really should just have this meta as atoms
	var segmentInfo : MkvAtom_SegmentInfo?
	var trackLists : [MkvAtom_TrackList]
	var tracks : [MkvAtom_TrackMeta]	{	trackLists.flatMap{ $0.tracks }	}
	var clusters : [MkvAtom_Cluster]
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		throw PopCodecError("todo: Segment decode")
	}
}


struct MkvAtom_SegmentInfo : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.info.fourcc
	
	var header: any Atom
	var childAtoms: [any Atom]?
	{
		segmentInfo.GetAtoms(parent:self)
	}
	
	//	really should just have this meta as atoms
	var segmentInfo : SegmentInfo
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var children : [any Atom] = []
		var timestampScale : UInt64?
		var duration : Double?
		var muxingApp : String?
		var writingApp : String?
		var title : String?
		
		while content.bytesRemaining > 0
		{
			let element = try await content.ReadEbmlElementHeader()

			switch element.type
			{
				case .timestampScale:
					timestampScale = try await content.readUInt(size: element.contentSize)
				case .duration:
					duration = try await content.readFloat(size: element.contentSize)
				case .muxingApp:
					muxingApp = try await content.readString(size: element.contentSize)
				case .writingApp:
					writingApp = try await content.readString(size: element.contentSize)
				case .title:
					title = try await content.readString(size: element.contentSize)
				default:
					children.append(element)
					try await content.SkipBytes(element.contentSize)
			}
		}
		
		let segmentInfo = SegmentInfo(
			timestampScale: timestampScale,
			durationMillisecondFloat: duration,
			muxingApp: muxingApp,
			writingApp: writingApp,
			title: title, 
			otherAtoms: children
		)
		return Self(header: header, segmentInfo: segmentInfo)
	}
}




struct MkvAtom_TrackList : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.tracks.fourcc
	
	var header: any Atom
	var childAtoms: [any Atom]?
	var tracks : [MkvAtom_TrackMeta]
	{
		childAtoms?.compactMap{ $0 as? MkvAtom_TrackMeta } ?? []
	}
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var children : [any Atom] = []
		//	ready all children
		while content.bytesRemaining > 0
		{
			var element = try await content.ReadEbmlElementHeader()
			
			var elementContent = try await content.GetReaderForBytes(byteCount: element.contentSize) as! DataReader
			
			if element.type == .trackEntry 
			{
				let track = try await MkvAtom_TrackMeta.Decode(header: element, content: &elementContent)
				children.append(track)
			}
			else
			{
				children.append(element)
			}
		}
		return Self(header: header, childAtoms: children)
	}
}


struct MkvAtom_TrackMeta : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.trackEntry.fourcc
	
	//	for app, is .name unique?
	//	should use .uid, but this is more readbale for now
	var trackUid : TrackUid	{	self.name ?? "\(self.number)"	}
	
	var header: any Atom
	var childAtoms: [any Atom]?
	{
		return codecMetas + children + GetMetaAtoms(parent: self)
	}

	var codecMetas : [any Atom]	{	[audioMeta as? any Atom, videoMeta as? any Atom].compactMap{$0} }
	var children : [any Atom]

	var number : UInt64
	var uid : UInt64
	var codecId : String?
	var name : String?
	var language: String?
	var defaultDurationNano: UInt64?
	var defaultDuration : Millisecond?	{	defaultDurationNano.map{ $0 / 1_000_000 }	}
	private var defaultDurationString : String	{	defaultDuration.map{ "\($0)ms" } ?? "null"	}
	var codecPrivate: Data?
	var audioMeta : MkvAtom_CodecMetaAudio?
	var videoMeta : MkvAtom_CodecMetaVideo?
	var trackTypeValue : UInt8?
	//	should default to video?
	var trackType : MkvTrackType?	{	trackTypeValue.map{ MkvTrackType(rawValue: $0) } ?? nil	}
	
	//	if we identify the codec, we auto decode the private data
	var codecPrivateDecodedAtom : (any Atom)?
	var codecDecodedAtomError : Error?
	
	func GetMetaAtoms(parent:any Atom) -> [any Atom]
	{
		let maybeAtoms : [(any Atom)?] = 
		[
			InfoAtom(info: "track number \(number)", parent: parent,uidOffset: 0),
			InfoAtom(info: "uid \(uid)", parent: parent,uidOffset: 1),
			InfoAtom(info: "codecId \(codecId)", parent: parent,uidOffset: 2),
			InfoAtom(info: "name \(name ?? "null")", parent: parent,uidOffset: 3),
			InfoAtom(info: "language \(language ?? "null")", parent: parent,uidOffset: 4),
			InfoAtom(info: "defaultDuration \(defaultDurationString)", parent: parent,uidOffset: 5),
			codecPrivateDecodedAtom,
			codecDecodedAtomError.map{ ErrorAtom(errorContext: "Decoding Codec Data", error: $0, erroredAtom: self) }
		]
		return maybeAtoms.compactMap{$0}
	}
	
	static func DecodeCodecPrivateData(codecId:String,codecData:Data) async throws -> (any Atom)?
	{
		let hevcId = "V_MPEGH/ISO/HEVC"
		let h264Id = "V_MPEG4/ISO/AVC"
		if codecId == h264Id
		{
			//	data is avcc atom
			let dummyAtomHeader = try AtomHeader(fourcc: Atom_avcc.fourcc, filePosition: 0, size: UInt32(codecData.count), size64: nil )
			var dataReader = DataReader(data: codecData)
			let atom = try await Atom_avcc.Decode(header: dummyAtomHeader, content: &dataReader)
			return atom
		}
		
		if codecId == hevcId
		{
			//	data is avcc atom
			let dummyAtomHeader = try AtomHeader(fourcc: Atom_hvcc.fourcc, filePosition: 0, size: UInt32(codecData.count), size64: nil)
			var dataReader = DataReader(data: codecData)
			let atom = try await Atom_hvcc.Decode(header: dummyAtomHeader, content: &dataReader)
			return atom
		}
		
		return nil
	}
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var number: UInt64 = 0
		var uid: UInt64 = 0
		var trackType : UInt8?
		var codecId : String?
		var name: String?
		var language: String?
		var defaultDurationNano: UInt64?
		var codecPrivate: Data?
		var audioMeta : MkvAtom_CodecMetaAudio?
		var videoMeta : MkvAtom_CodecMetaVideo?
		var children : [any Atom] = []
		
		while content.bytesRemaining > 0
		{
			let element = try await content.ReadEbmlElementHeader()
			
			switch element.type
			{
				case .trackNumber:
					number = try await content.readUInt(size: element.contentSize)
				case .trackUID:
					uid = try await content.readUInt(size: element.contentSize)
				case .trackType:
					let value = try await content.readUInt(size: element.contentSize)
					trackType = UInt8(value)
					
				case .codecID:
					codecId = try await content.readString(size: element.contentSize)
				case .codecPrivate:
					codecPrivate = try await content.ReadBytes(element.contentSize)
				case .name:
					name = try await content.readString(size: element.contentSize)
				case .language:
					language = try await content.readString(size: element.contentSize)
				case .defaultDuration:
					defaultDurationNano = try await content.readUInt(size: element.contentSize)
				case .video:
					var videoContent = try await content.GetReaderForBytes(byteCount: element.contentSize) as! DataReader
					videoMeta = try await MkvAtom_CodecMetaVideo.Decode(header: element, content: &videoContent)
				case .audio:
					var audioContent = try await content.GetReaderForBytes(byteCount: element.contentSize) as! DataReader
					audioMeta = try await MkvAtom_CodecMetaAudio.Decode(header: element, content: &audioContent)
				default:
					children.append(element)
					try await content.SkipBytes(element.contentSize)
			}
		}
		
		var codecAtom : (any Atom)?
		var codecDecodedAtomError : Error?
		if let codecId, let codecPrivate
		{
			do
			{
				codecAtom = try await DecodeCodecPrivateData(codecId:codecId,codecData:codecPrivate)
			}
			catch
			{
				codecDecodedAtomError = error
			}
		}
		
		return Self(header: header,children: children, number: number, uid:uid, codecId: codecId, codecPrivate: codecPrivate, audioMeta:audioMeta, videoMeta:videoMeta, trackTypeValue:trackType, codecPrivateDecodedAtom:codecAtom, codecDecodedAtomError:codecDecodedAtomError)
	}
}

struct MkvAtom_CodecMetaVideo : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.video.fourcc
	
	var header: any Atom
	var childAtoms: [any Atom]?
	{
		return [
			pixelWidth.map{ InfoAtom(info: "Width \($0)", parent: self, uidOffset: 0) },
			pixelHeight.map{ InfoAtom(info: "Height \($0)", parent: self, uidOffset: 1) },
			displayWidth.map{ InfoAtom(info: "Display Width \($0)", parent: self, uidOffset: 2) },
			displayHeight.map{ InfoAtom(info: "Display Height \($0)", parent: self, uidOffset: 3) },
		].compactMap{$0} + unknownChildren
	}
	var pixelWidth: UInt64?
	var pixelHeight: UInt64?
	var displayWidth: UInt64?
	var displayHeight: UInt64?
	var unknownChildren : [any Atom]
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var pixelWidth: UInt64?
		var pixelHeight: UInt64?
		var displayWidth: UInt64?
		var displayHeight: UInt64?
		var unknownChildren : [any Atom] = []

		while content.bytesRemaining > 0
		{
			var element = try await content.ReadEbmlElementHeader()
			
			switch element.type
			{
				case .pixelWidth:			pixelWidth = try await content.readUInt(size: element.size)
				case .pixelHeight:			pixelHeight = try await content.readUInt(size: element.size)
				case .displayWidth:			displayWidth = try await content.readUInt(size: element.size)
				case .displayHeight:		displayHeight = try await content.readUInt(size: element.size)
					
				default:
					unknownChildren.append(element)
					try await content.SkipBytes(element.contentSize)
			}
		}
		
		return Self(header: header,
					pixelWidth: pixelWidth,
					pixelHeight: pixelHeight,
					displayWidth: displayWidth,
					displayHeight: displayHeight,
					unknownChildren: unknownChildren)
	}
}


struct MkvAtom_CodecMetaAudio : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.audio.fourcc
	
	var header: any Atom
	var childAtoms: [any Atom]?
	{
		[
			samplingFrequency.map{ InfoAtom(info: "Sample Frequency \($0)", parent: self, uidOffset: 0 ) },
			channels.map{ InfoAtom(info: "channels x\($0)", parent: self, uidOffset: 1 ) },
			bitDepth.map{ InfoAtom(info: "bitDepth \($0)", parent: self, uidOffset: 2 ) },
		].compactMap{$0}
	}
	
	//	todo: show these as info atoms	
	var samplingFrequency: Double?
	var channels: UInt64?
	var bitDepth: UInt64?
	var unknownAtoms : [any Atom]
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var samplingFrequency: Double?
		var channels: UInt64?
		var bitDepth: UInt64?
		var unknownAtoms: [any Atom] = []
		
		while content.bytesRemaining > 0
		{
			var element = try await content.ReadEbmlElementHeader()
			unknownAtoms.append(element)
			
			switch element.type
			{
				case .samplingFrequency:	samplingFrequency = try await content.readFloat(size: element.size)
				case .channels:				channels = try await content.readUInt(size: element.size)
				case .bitDepth:				bitDepth = try await content.readUInt(size: element.size)
					
				default:
					try await content.SkipBytes(element.contentSize)
			}
		}
		
		return Self(header: header, samplingFrequency: samplingFrequency, channels: channels, bitDepth: bitDepth,unknownAtoms: unknownAtoms)
	}
}

struct MkvAtom_Cluster : Atom, SpecialisedAtom
{
	static var fourcc = EBMLElementID.cluster.fourcc
	
	var header: any Atom
	var childAtoms: [any Atom]?
	{
		[
			InfoAtom(info: "Timestamp \(clusterTimestampString)", parent: self, uidOffset: 0)
		]
		+ childElements
	}
	
	var childElements : [any Atom]
	
	var clusterTimestampUnscaled : UInt64?
	var clusterTimestampString : String		{	clusterTimestampUnscaled.map{"\($0)"} ?? "null"	}
	
	//	samples are always stored in decode order
	let samplesPerTrackNumberInDecodeOrder : [UInt64:[MkvAtom_SimpleBlock]]
	

	static func Decode(header:any Atom, content:inout DataReader) async throws -> Self
	{
		var clusterTimestampUnscaled : UInt64?
		
		//	sort these into tracks
		var samplesPerTrackNumber: [UInt64:[MkvAtom_SimpleBlock]] = [:]
		//var groupSamples: [UInt64:[MkvAtom_GroupBlock]] = [:]
		var childElements : [any Atom] = []
		
		func AddSamples(_ samples:[MkvAtom_SimpleBlock])
		{
			guard let trackNumber = samples.first?.trackNumber else
			{
				//	no samples
				return
			}
			samplesPerTrackNumber[trackNumber] = samplesPerTrackNumber[trackNumber] ?? []
			samplesPerTrackNumber[trackNumber]!.append(contentsOf: samples)
		}
		
		while content.bytesRemaining > 0
		{
			var element = try await content.ReadEbmlElementHeader()
			
			var childContent = try await content.GetReaderForBytes(byteCount: element.contentSize) as! DataReader
			
			switch element.type
			{
				case .timestamp:
					clusterTimestampUnscaled = try await childContent.readUInt(size: element.size)
					childElements.append(element)
				
				case .simpleBlock:
					//	skip parsing samples - except first
					if samplesPerTrackNumber.isEmpty
					{
						let sampleRaw = try await MkvAtom_SimpleBlock.Decode(header: element, content: &childContent)
						AddSamples([sampleRaw])
						childElements.append(sampleRaw)
					}
					break
				
				case .blockGroup:
					//	skip parsing samples - except first
					if samplesPerTrackNumber.isEmpty
					{
						let groupBlock = try await MkvAtom_GroupBlock.Decode(header: element, content: &childContent)
						for trackNumber in groupBlock.samplesPerTrackNumber.keys
						{
							let groupSamples = groupBlock.samplesPerTrackNumber[trackNumber]!
							AddSamples(groupSamples)
						}
						childElements.append(groupBlock)
					}
					break
			
				default:
					//print("Unknown cluster element \(element.fourcc) x\(element.contentSize)")
					childElements.append(element)
			}
		}
		
		return Self(header: header, childElements:childElements, clusterTimestampUnscaled:clusterTimestampUnscaled,  samplesPerTrackNumberInDecodeOrder: samplesPerTrackNumber)
	}

}


typealias MkvAtom_Block = MkvAtom_SimpleBlock

//	this is same data inside as .block
struct MkvAtom_SimpleBlock : Atom, SpecialisedAtom
{
	//	gr: this is also sample as .block!
	static var fourcc: Fourcc	{	EBMLElementID.simpleBlock.fourcc	}
	
	var childAtoms: [any Atom]?
	{[
		InfoAtom(info: "trackNumber=\(trackNumber)", parent: self, uidOffset: 0),
		InfoAtom(info: "flags=\(flags)", parent: self, uidOffset: 1),
		InfoAtom(info: "keyframe=\(isKeyframe)", parent: self, uidOffset: 2),
		InfoAtom(info: "relativeTimestampUnscaled=\(relativeTimestampUnscaled)", parent: self, uidOffset: 3),
		InfoAtom(info: "data", filePosition:sampleDataFilePosition, totalSize: sampleDataSize)
	]}
	
	var header: any Atom
	
	var sampleDataFilePosition : UInt64
	var sampleDataSize : UInt64
	var trackNumber : UInt64
	var isKeyframe : Bool	{	(flags & 0x80) != 0	}
	var flags : UInt8
	var relativeTimestampUnscaled : Int16
	
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		let startOffset = content.globalPosition
		let endOffset = startOffset + content.bytesRemaining
		
		// Read track number (variable-length)
		let trackNumber = try await content.readVIntSize()
		
		let relativeTimestampUnscaledUnsigned = try await content.Read16()
		/*
		// Read timestamp (2 bytes, signed)
		guard offset + 2 <= data.count else {
			throw MKVError.endOfData
		}
		let timestampBytes = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
		let relativeTimestampUnscaled = Int16(bitPattern: timestampBytes)
		offset += 2
		 */
		let relativeTimestampUnscaled = Int16(bitPattern: relativeTimestampUnscaledUnsigned)
		
		let flags = try await content.Read8()
		
		// Calculate frame data location
		let sampleDataFilePosition = content.globalPosition
		let dataSize = content.bytesRemaining
		
		//	just to validate size
		try await content.SkipBytes(dataSize)

		// Assign decode timestamp (in file order)
		//let decodeTimestamp = assignDecodeTimestamp(trackNumber: trackNumber, timestampScale: Int64(timestampScale))

		return Self(header: header, sampleDataFilePosition: sampleDataFilePosition, sampleDataSize: dataSize, trackNumber: trackNumber, flags: flags, relativeTimestampUnscaled: relativeTimestampUnscaled)
	}
}



struct MkvAtom_GroupBlock : Atom, SpecialisedAtom
{
	static var fourcc: Fourcc	{	EBMLElementID.simpleBlock.fourcc	}
	
	var childAtoms: [any Atom]?
	
	var header: any Atom
	
	var hasReferenceBlock : Bool
	var isKeyframe : Bool		{	return !hasReferenceBlock	}
	var durationUnscaled : UInt64?
	var samplesPerTrackNumber : [UInt64:[MkvAtom_Block]]
	
	static func Decode(header: any Atom, content: inout DataReader) async throws -> Self 
	{
		var hasReferenceBlock = false
		var durationUnscaled : UInt64?
		var samplesPerTrackNumber : [UInt64:[MkvAtom_Block]] = [:]
		var children : [any Atom] = []
		
		while content.bytesRemaining > 0
		{
			let element = try await content.ReadEbmlElementHeader()
			var elementContent = try await content.GetReaderForBytes(byteCount: element.contentSize) as! DataReader
			
			children.append(element)
			
			switch element.type
			{
				case .block:
					let blockAtom = try await MkvAtom_Block.Decode(header: element, content: &elementContent)
					samplesPerTrackNumber[blockAtom.trackNumber] = samplesPerTrackNumber[blockAtom.trackNumber] ?? []
					samplesPerTrackNumber[blockAtom.trackNumber]!.append(blockAtom)
					
				case .blockDuration:
					durationUnscaled = try await elementContent.readUInt(size: element.contentSize)
					
				case .referenceBlock:
					print("Is there data here in referecne block? x\(element.contentSize)")
					hasReferenceBlock = true
					
				default:
					break
			}
		}
			
		return Self(childAtoms: children, header: header, hasReferenceBlock: hasReferenceBlock, durationUnscaled:durationUnscaled, samplesPerTrackNumber: samplesPerTrackNumber)
	}
}

