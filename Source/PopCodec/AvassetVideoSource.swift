import AVFoundation
import Combine

extension AVMediaType
{
	var encodingType : TrackEncoding
	{
		switch self
		{
			case .video:			return .Video(H264Codec())
			case .audio:			return .Audio
			case .text:				return .Text
			case .subtitle:			return .Text
			case .closedCaption:	return .Text
			default:				return .Unknown
		}
	}
}

extension AVAssetTrack
{
	func GetDurationMs() async throws -> Millisecond
	{
		let timeRange = try await self.load(.timeRange)
		return timeRange.duration.milliseconds
	}
}

class AVAssetVideoSource : ObservableObject, VideoSource
{
	static func DetectIsFormat(headerData: Data) async -> Bool 
	{
		return false
	}
	
	var defaultSelectedTrack: TrackUid? { nil }
	var typeName: String { "AVAssetVideoSource" }
	
	var url : URL
	var asset : AVURLAsset
	@Published var atoms: [any Atom] = []
	@Published var tracks: [TrackMeta] = []
	
	var loadAssetTask : Task<[TrackMeta],Error>!
	
	required init(url: URL)
	{
		self.url = url
		self.asset = AVURLAsset(url: url)
		loadAssetTask = Task(operation: LoadAsset)
	}
	
	func WatchAtoms(onAtomsChanged: @escaping ([any Atom]) -> Void)
	{
		// Implement proper observable hook if your atoms change in the future
	}
	
	func WatchTracks(onTracksChanged: @escaping ([TrackMeta]) -> Void)
	{
		// Implement proper observable hook if your tracks change in the future
	}
	
	func WatchTrackSampleKeyframes(onTrackSampleKeyframesChanged: @escaping (TrackUid) -> Void)
	{
		// Stub: implement if/when keyframes change
	}
	
	func LoadAsset() async throws -> [TrackMeta]
	{
		let pathString  = asset.url.path(percentEncoded: false)
		if !FileManager.default.fileExists(atPath: pathString)
		{
			throw PopCodecError("File doesnt exist \(pathString)")
		}
		
		let assetTracks = try await asset.load(.tracks)
		var outputTracks : [TrackMeta] = []

		for assetTrack in assetTracks
		{ 
			let duration = try? await assetTrack.GetDurationMs()
			let trackId = "\(assetTrack.trackID)"
			let encoding = assetTrack.mediaType.encodingType
			outputTracks.append(TrackMeta(id: trackId, duration: duration ?? 0, encoding: encoding))
		}
		return outputTracks
	}

	func GetAtomData(atom: any Atom) async throws -> Data
	{
		throw PopCodecError("GetAtomData not implemented")
	}
	
	func GetTrackMetas() async throws -> [TrackMeta]
	{
		let tracks = try await loadAssetTask.value
		return tracks
	}
	
	func GetTrackSampleManager(track: TrackUid) throws -> TrackSampleManager
	{
		throw PopCodecError("Todo: GetTrackSampleManager")
	}

	func GetTrackMeta(trackUid: TrackUid) throws -> TrackMeta
	{
		guard let track = tracks.first(where: { $0.id == trackUid }) else {
			throw DataNotFound("No such track \"\(trackUid)\"")
		}
		return track
	}
	
	func GetFrameData(frame: TrackAndTime) async throws -> Data
	{
		throw PopCodecError("GetFrameData not implemented")
	}
	
	func AllocateTrackDecoder(track: TrackMeta) -> (any TrackDecoder)?
	{
		return nil
	}
}
