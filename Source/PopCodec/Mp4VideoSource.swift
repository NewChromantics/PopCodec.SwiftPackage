import Foundation
import Combine





//	would like to use ByteReader here, but cannot inout a protocol
//	https://stackoverflow.com/questions/37486272/can-i-use-inout-with-protocol-extensions
//	may just force it to be super class rather than protocol
func ReadMp4Header(reader:inout DataReader,onFoundAtom:(Atom)async throws->Void) async throws
{
	//	safety loop
	//	10,000 atoms could be possible in a weird instance or very long progressive mp4
	let safetyLimit = 10000
	for it in 0..<safetyLimit
	{
		do
		{
			let atom = try await reader.ReadAtom()
			try await onFoundAtom(atom)
		}
		catch is EndOfDataError
		{
			return
		}
	}
	throw PopCodecError("ReadMp4Header aborted after \(safetyLimit) iterations")
}
/*
import Foundation

/// Read text file line by line in efficient way
public class LineReader {
	public let path: String
	
	fileprivate let file: UnsafeMutablePointer<FILE>!
	
	init?(path: String) {
		self.path = path
		file = fopen(path, "r")
		guard file != nil else { return nil }
	}
	
	public var nextLine: String? {
		var line: UnsafeMutablePointer<CChar>?
		var linecap: Int = 0
		defer { free(line) }
		return getline(&line, &linecap, file) > 0 ? String(cString: line!) : nil
	}
	
	deinit {
		fclose(file)
	}
}

extension LineReader: Sequence {
	public func makeIterator() -> AnyIterator<String> {
		return AnyIterator<String> {
			return self.nextLine
		}
	}
}
*/

struct Mp4Header
{
	var atoms : [any Atom] = []
	var tracks : [TrackMeta] = []
	
	
	func ExtractTracks() throws -> [TrackMeta]
	{
		let moov = try GetAtom(fourcc: Fourcc("moov"))
		let traks = moov.childAtoms?.compactMap{ $0 as? Atom_trak } ?? []
		return traks.enumerated().map
		{
			trackIndex,trackAtom in
			let samples = trackAtom.samplesInPresentationOrder
			let firstTime = samples.first.map{Millisecond($0.presentationTime)}
			let lastTime = samples.last.map{Millisecond($0.presentationTime)}
			let duration = lastTime.map{ $0 - (firstTime ?? 0) } ?? 0
			
			//	mp4 tracks start at number 1, but this is really just an arbritrary id
			let trackId = "\(trackIndex+1)"
			return TrackMeta(id: trackId, startTime:firstTime, duration:duration, encoding: trackAtom.encoding, samples: samples)
		}
	}
	
	func GetAtom(fourcc:Fourcc) throws -> any Atom
	{
		guard let match = atoms.first(where: {$0.fourcc == fourcc}) else
		{
			throw DataNotFound("No such atom \(fourcc)")
		}
		return match
	}
}

public class Mp4VideoSource : VideoSource
{
	public var typeName: String	{"Mpeg"}
	public var defaultSelectedTrack: TrackUid? = nil
	
	var url : URL
	var readHeaderTask : Task<Mp4Header,Error>!	//	promise
	
	required public init(url:URL)
	{
		self.url = url
		
		readHeaderTask = Task(operation: ReadHeader)
	}
	
	func ReadHeader() async throws -> Mp4Header
	{
		var fileData = try Data(contentsOf:url, options: .alwaysMapped)
		var fileReader = DataReader(data: fileData)
		
		var header = Mp4Header()
		
		try await ReadMp4Header(reader: &fileReader)
		{
			atom in
			print("Found atom \(atom.fourcc) content size x\(atom.contentSize)")
			header.atoms.append(atom)
		}
		
		//	pull tracks out of atoms
		let tracks = try header.ExtractTracks()
		header.tracks = tracks
		
		defaultSelectedTrack = tracks.first{$0.encoding.isVideo}?.id
		
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
		//	only need to search start of mp4
		let headerData = headerData[0..<1000]
		
		var reader = DataReader(data: headerData)
		var hasFoundTypAtom = false
		do
		{
			try await ReadMp4Header(reader: &reader)
			{
				atom in
				if atom.fourcc == Fourcc("ftyp")
				{
					hasFoundTypAtom = true
				}
			}
			return hasFoundTypAtom
		}
		catch
		{
			if hasFoundTypAtom
			{
				return true
			}
			print("Detecting mp4 error; \(error.localizedDescription). Assuming not mp4")
			return false
		}
	}
	

	
}
