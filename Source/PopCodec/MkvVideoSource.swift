import Foundation


struct MkvHeader
{
	var atoms : [any Atom]
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
		throw PopCodecError("todo: decode mkv header")
	}
	
	public func GetTrackMetas() async throws -> [TrackMeta] 
	{
		throw PopCodecError("todo: mkv GetTrackMetas")
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
			print("Detecting mp4 error; \(error.localizedDescription). Assuming not mp4")
			return false
		}
	}
	
	
	
}
