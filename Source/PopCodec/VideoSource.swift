import Foundation
import AVFoundation
//import PopCommon
import SwiftUI
import Combine
//import Timeline

public typealias TrackUid = String


//	reference to a frame on a track
public struct TrackAndTime : Hashable
{
	public var track : TrackUid
	public var time : Millisecond
	
	public init(track: TrackUid, time: Millisecond) 
	{
		self.track = track
		self.time = time
	}
}


public func DetectVideoSourceType(headerData:Data) async -> [VideoSource.Type]
{
	let possibleVideoTypes = [Mp4VideoSource.self]
	var detectedVideoTypes : [VideoSource.Type] = []
	
	for possibleVideoType in possibleVideoTypes
	{
		let isType = await possibleVideoType.DetectIsFormat(headerData: headerData)
		if !isType
		{
			continue
		}
		detectedVideoTypes.append( possibleVideoType )
	}
	
	return detectedVideoTypes
}



enum BinaryChopCompare
{
	case Equals,LessThan,GreaterThan
}

extension Array
{
	func FindNearestIndexWithBinaryChop(compare:(Element)->BinaryChopCompare) -> Int?
	{
		if self.isEmpty
		{
			return nil
		}
		
		var left = 0
		var right = self.count-1
		
		while left < right
		{
			switch compare(self[left])
			{
				case .LessThan:		break
				case .Equals:		return left
				case .GreaterThan:	return left
			}
			switch compare(self[right])
			{
				case .LessThan:	return right
				case .Equals:	return right
				case .GreaterThan:	break
			}

			//	make sure we dont get stuck, when there's no more indexes!
			if left + 1 == right
			{
				return left
			}
				
			let mid = left + (( right - left ) / 2)
			//print("left=\(left) right=\(right) mid=\(mid)")
			
			switch compare(self[mid])
			{
				case .Equals:	return mid
				case .LessThan:
					if left == mid
					{
						return mid
					}
					left = mid
				case .GreaterThan:
					if right == mid
					{
						return mid
					}
					right = mid
			}
		}
		return left
	}
}


public enum TrackEncoding : CustomStringConvertible
{
	
	case Video(Codec),
		 Audio,
		 Text,	//	in future, specifically subtitle or not
		 Unknown
	
	public var description: String	{	label	}

	var isVideo : Bool
	{
		switch self
		{
			case .Video(_):	return true
			default:	return false
		}
	}
	
	var label : String
	{
		switch self
		{
			case .Video(let codec):	return "\(codec.name) Video"
			case .Audio:	return "Audio"
			case .Text:		return "Text"
			case .Unknown:	return "Unknown"
		}
	}
	
	var icon : String
	{
		switch self
		{
			case .Video(_):	return "video"
			case .Audio:	return "waveform.path"
			case .Text:		return "textformat.characters"
			case .Unknown:	return "questionmark.square.dashed"
		}
	}
}

func clamp(_ x:Int, min: Int, max: Int) -> Int
{
	return Swift.max( min, Swift.min( max, x ) )
}	

func clampRange(from:Int,to:Int,min:Int,max:Int) -> ClosedRange<Int>
{
	let from = clamp(from,min:min,max:max)
	let to = clamp(to,min:min,max:max)
	return from...to
}
	

public struct TrackMeta : Identifiable
{
	public var id : TrackUid
	public var startTime : Millisecond?
	public var duration : Millisecond
	public var endTime : Millisecond?	{	duration + (self.startTime ?? 0) }
	public var encoding : TrackEncoding
	
	//	will all formats know this data ahead of time?
	public var samples : [Mp4Sample]		//	should be in presentation order
	
	//	if no keyframes, should we return 0th? and if 0th is not a keyframe, does that mean there's never a keyframe?
	//	or if there is no keyframe/sync atom, does that also mean there's no keyframe?
	//	might be room for lots of optimisation here.
	public var keyframeSamples : [Mp4Sample]	{	samples.filter{ $0.isKeyframe }	}
	
	public var icon : String		{	encoding.icon	}
	public var label : String
	{
		return "\(id) \(encoding.label)"
	}
	
	public func GetFrameTimeLessOrEqualToTime(_ time:Millisecond,keyframe:Bool) -> Millisecond?
	{
		guard let sample = GetSampleLessOrEqualToTime(time,keyframe:keyframe) else
		{
			return nil
		}
		return Millisecond(sample.presentationTime)
	}
	
	func GetSampleLessOrEqualToTime(_ time:Millisecond,keyframe:Bool) -> Mp4Sample?
	{
		let searchSamples = keyframe ? keyframeSamples : samples
		
		let index = GetSampleIndexLessOrEqualToTime(time,keyframe: keyframe)
		return index.map
		{
			index in
			return searchSamples[index]
		}
	}
	
	public func GetSampleIndexLessOrEqualToTime(_ time:Millisecond,keyframe:Bool) -> Int?
	{
		let searchSamples = keyframe ? keyframeSamples : samples
		
		let index = searchSamples.FindNearestIndexWithBinaryChop
		{
			if $0.presentationTime == time	
			{	
				return .Equals	
			}
			if $0.presentationTime < time		
			{	
				return .LessThan
			}
			return .GreaterThan
		}
		return index
	}
	
	
	public func GetSamples(minTime:Millisecond,maxTime:Millisecond) -> ArraySlice<Mp4Sample>
	{
		//	no samples!
		guard let lastSample = samples.last, let firstSample = samples.first else
		{
			return []
		}
		
		//	skip long searches if we wont hit
		if lastSample.presentationEndTime < minTime || firstSample.presentationTime > maxTime
		{
			return []
		}
		
		//	start in a sensible place
		let minIndex = samples.FindNearestIndexWithBinaryChop
		{
			if $0.presentationTime == minTime	
			{	
				return .Equals	
			}
			if $0.presentationTime < minTime		
			{	
				return .LessThan
			}
			return .GreaterThan
		} ?? 0
		let maxIndex = samples.FindNearestIndexWithBinaryChop
		{
			if $0.presentationTime == maxTime	
			{	
				return .Equals
			}
			if $0.presentationTime < maxTime	
			{	
				return .LessThan
			}
			return .GreaterThan
		} ?? 0
		
		return samples[minIndex...maxIndex]
	}
}


public protocol VideoSource : ObservableObject
{
	var typeName : String			{	get	}
	var defaultSelectedTrack : TrackUid?	{	get	}		//	if nothing selected, "show" this track (ie. default to pixels in video)
	
	static func DetectIsFormat(headerData:Data) async -> Bool
	
	init(url:URL)
	func GetTrackMetas() async throws -> [TrackMeta]
	func GetAtoms() async throws -> [any Atom]				//	meta essentially
	func GetFrameData(frame:TrackAndTime) async throws -> Data
	func GetAtomData(atom:any Atom) async throws -> Data
	func AllocateTrackDecoder(track:TrackMeta) -> (any TrackDecoder)?
}

extension VideoSource
{
	//	default
	func GetAtoms() async throws -> [any Atom] 
	{
		return []
	}

	func GetFrameData(frame:TrackAndTime) async throws -> Data
	{
		throw PopCodecError("GetFrameData not implemented")
	}
	
	func GetTrackMeta(trackUid:TrackUid) async throws -> TrackMeta 
	{
		let tracks = try await GetTrackMetas()
		let track = tracks.first{ $0.id == trackUid }
		guard let track else
		{
			throw DataNotFound("No such track \"\(trackUid)\"")
		}
		return track
	}
	
	//	default
	func AllocateTrackDecoder(track:TrackMeta) -> (any TrackDecoder)?
	{
		return nil
	}
}
/*
class VideoSourceFactory
{
	//	factory
	static func Allocate(url:URL?) throws -> any VideoSource
	{
		guard let url else
		{
			throw AppError("Missing url to file")
		}
		return TestVideoSource(url:url)
	}
}
*/

class TestVideoSource : VideoSource
{
	
	required init(url: URL) 
	{
	}
	
	var defaultSelectedTrack: TrackUid?	{"Video1"}
	var typeName: String	{"TestVideoSource"}
	
	
	func GetAtomData(atom: any Atom) async throws -> Data 
	{
		throw PopCodecError("GetAtomData not implemented")
	}
	

	func GetTrackMetas() async throws -> [TrackMeta] 
	{
		//await Task.sleep(milliseconds: 1000)
		return [
			TrackMeta(id: "Video1", duration: 60*1000, encoding: .Video(H264Codec()), samples: []),
			TrackMeta(id: "Audio1",  duration: 1*1000, encoding: .Audio, samples: [])
			]
	}
	
	static func DetectIsFormat(headerData: Data) async -> Bool 
	{
		return false
	}
}
