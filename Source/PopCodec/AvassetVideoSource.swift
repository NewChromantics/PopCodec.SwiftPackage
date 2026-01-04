import AVFoundation
import Combine
//import Testing


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


class AVAssetVideoSource : VideoSource
{
	var defaultSelectedTrack: TrackUid?{nil}
	var typeName: String	{"AVAssetVideoSource"}
	
	var url : URL
	var asset : AVURLAsset
	
	var loadAssetTask : Task<[TrackMeta],Error>!
	
	init(url:URL)
	{
		self.url = url
		self.asset = AVURLAsset(url: url)
		
		loadAssetTask = Task(operation: LoadAsset)
	}
	
	func LoadAsset() async throws -> [TrackMeta] 
	{
		//	show a better error if the file doesnt exist
		let pathString  = asset.url.path(percentEncoded: false)
		if !FileManager.default.fileExists(atPath: pathString)
		{
			throw PopCodecError("File doesnt exist \(pathString)")
		}
		
		//let assetTracks = try await asset.loadTracks(withMediaCharacteristic: .frameBased)
		let assetTracks = try await asset.load(.tracks)
		var outputTracks : [TrackMeta] = []

		for assetTrack in assetTracks
		{ 
			let duration = try? await assetTrack.GetDurationMs()
			let trackId = "\(assetTrack.trackID)"
			let encoding = assetTrack.mediaType.encodingType
			outputTracks.append( TrackMeta(id: trackId, duration: duration, encoding: encoding, samples: []) )
		}
		return outputTracks
	}
	
	func GetTrackMetas() async throws -> [TrackMeta] 
	{
		let tracks = try await loadAssetTask.value
		return tracks
	}
	
	
}
