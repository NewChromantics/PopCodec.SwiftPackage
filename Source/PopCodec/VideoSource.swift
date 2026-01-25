import Foundation
import AVFoundation
//import PopCommon
import SwiftUI
import Combine
//import Timeline

public typealias TrackUid = String


//	reference to a frame on a track
public struct TrackAndTime : Hashable, CustomStringConvertible
{
	public var track : TrackUid
	public var time : Millisecond
	
	public var description: String	{	"\(time)ms [\(track)]"	}
	
	public init(track: TrackUid, time: Millisecond) 
	{
		self.track = track
		self.time = time
	}
}


public func DetectVideoSourceType(headerData:Data) async -> [VideoSource.Type]
{
	let possibleVideoTypes : [VideoSource.Type] = [Mp4VideoSource.self,MkvVideoSource.self]
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



public enum BinaryChopCompare
{
	case Equals,LessThan,GreaterThan
}

public extension Array
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

	public var isVideo : Bool
	{
		switch self
		{
			case .Video(_):	return true
			default:	return false
		}
	}
	
	public var label : String
	{
		switch self
		{
			case .Video(let codec):	return "\(codec.name) Video"
			case .Audio:	return "Audio"
			case .Text:		return "Text"
			case .Unknown:	return "Unknown"
		}
	}
	
	public var icon : String
	{
		switch self
		{
			case .Video(_):	return "video"
			case .Audio:	return "waveform.path"
			case .Text:		return "textformat.characters"
			case .Unknown:	return "questionmark.square.dashed"
		}
	}
	
	//	for various styling
	public var colour : NSColor
	{
		switch self
		{
			case .Video(_):	return .blue
			case .Audio:	return .green
			case .Text:		return .yellow
			case .Unknown:	return .red
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
	
	//	gr: if start & end dont exist, we should look at first/last samples'
	public var startTime : Millisecond?
	public var duration : Millisecond?
	public var endTime : Millisecond?	
	{
		let startTime = startTime ?? 0
		return duration.map{ startTime + $0 }
	}
	
	public var encoding : TrackEncoding
	
	

	public var icon : String		{	encoding.icon	}
	public var label : String		{	return "\(id) \(encoding.label)"	}
	public var colour : NSColor		{	encoding.colour	}
	
}



public protocol TrackSampleManager
{
	//	current state
	//	should be in presentation order
	//	but mkv, we could pre-empt many in decode order when not knowing presentation order...
	var samples : [Mp4Sample]	{get}		
	
	//	if no keyframes, should we return 0th? and if 0th is not a keyframe, does that mean there's never a keyframe?
	//	or if there is no keyframe/sync atom, does that also mean there's no keyframe?
	//	might be room for lots of optimisation here.
	var keyframeSamples : [Mp4Sample]	{get}
}


public extension TrackSampleManager
{
	//	default implementation
	//	if no keyframes, should we return 0th? and if 0th is not a keyframe, does that mean there's never a keyframe?
	//	or if there is no keyframe/sync atom, does that also mean there's no keyframe?
	//	might be room for lots of optimisation here.
	public var keyframeSamples : [Mp4Sample]	{	samples.filter{ $0.isKeyframe }	}
	
	
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
	
	
	public func GetSamples(minTime:Millisecond,maxTime:Millisecond,byPresentationTime:Bool=true) -> ArraySlice<Mp4Sample>
	{
		if byPresentationTime
		{
			return GetPresentationSamples(minTime: minTime, maxTime: maxTime)
		}
		else
		{
			return GetDecodeTimeSamples(minTime: minTime, maxTime: maxTime)
		}
	}

	
	private func GetPresentationSamples(minTime:Millisecond,maxTime:Millisecond) -> ArraySlice<Mp4Sample>
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
	
	private func GetDecodeTimeSamples(minTime:Millisecond,maxTime:Millisecond) -> ArraySlice<Mp4Sample>
	{
		//	no samples!
		guard let lastSample = samples.last, let firstSample = samples.first else
		{
			return []
		}
		
		//	skip long searches if we wont hit
		if lastSample.decodeEndTime < minTime || firstSample.decodeTime > maxTime
		{
			return []
		}
		
		//	start in a sensible place
		let minIndex = samples.FindNearestIndexWithBinaryChop
		{
			if $0.decodeTime == minTime	
			{	
				return .Equals	
			}
			if $0.decodeTime < minTime		
			{	
				return .LessThan
			}
			return .GreaterThan
		} ?? 0
		let maxIndex = samples.FindNearestIndexWithBinaryChop
		{
			if $0.decodeTime == maxTime	
			{	
				return .Equals
			}
			if $0.decodeTime < maxTime	
			{	
				return .LessThan
			}
			return .GreaterThan
		} ?? 0
		
		return samples[minIndex...maxIndex]
	}
}

public class Mp4TrackSampleManager : TrackSampleManager
{
	//	will all formats know this data ahead of time?
	public var samples : [Mp4Sample]	//	should be in presentation order
	
	init(samples:[Mp4Sample]=[])
	{
		self.samples = samples
	}
	
}


public protocol VideoSource : ObservableObject
{
	var typeName : String			{	get	}
	
	static func DetectIsFormat(headerData:Data) async -> Bool
	
	init(url:URL)

	//	newer observable access as we assume this changes as it streams
	var atoms : [any Atom]	{get}
	func WatchAtoms(onAtomsChanged:@escaping([any Atom])->Void)

	var tracks : [TrackMeta]	{get}
	func WatchTracks(onTracksChanged:@escaping([TrackMeta])->Void)
	func GetTrackMeta(trackUid:TrackUid) throws -> TrackMeta 		//	no longer async, immediate access
	
	//	sync as we want to work on whatever data exists right now
	func GetTrackSampleManager(track:TrackUid) throws -> TrackSampleManager
	
	func GetFrameData(frame:TrackAndTime) async throws -> Data
	func GetAtomData(atom:any Atom) async throws -> Data
	func AllocateTrackDecoder(track:TrackMeta) -> (any TrackDecoder)?
}

public extension VideoSource
{
	func GetRootAtom(fourcc:Fourcc) throws -> any Atom
	{
		let match = self.atoms.first{ $0.fourcc == fourcc }
		guard let match else
		{
			throw DataNotFound("No root atom \(fourcc)")
		}
		return match
	}
	
	func GetFrameData(frame:TrackAndTime) async throws -> Data
	{
		throw PopCodecError("GetFrameData not implemented")
	}
	
	func GetTrackMeta(trackUid:TrackUid) throws -> TrackMeta 
	{
		let track = tracks.first{ $0.id == trackUid }
		guard let track else
		{
			throw DataNotFound("No such track \"\(trackUid)\"")
		}
		return track
	}
	
	func GetTrackSamples(trackUid:TrackUid) async throws -> TrackSampleManager
	{
		throw PopCodecError("todo")
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
	var atoms: [any Atom] = []
	var tracks: [TrackMeta] = []
	
	required init(url: URL) 
	{
	}
	
	var defaultSelectedTrack: TrackUid?	{"Video1"}
	var typeName: String	{"TestVideoSource"}
	
	func WatchAtoms(onAtomsChanged:@escaping([any Atom]) -> Void) 
	{
	}
	
	
	func WatchTracks(onTracksChanged:@escaping([TrackMeta]) -> Void) 
	{
	}
	
	
	func GetAtomData(atom: any Atom) async throws -> Data 
	{
		throw PopCodecError("GetAtomData not implemented")
	}
	

	func GetTrackMetas() async throws -> [TrackMeta] 
	{
		//await Task.sleep(milliseconds: 1000)
		return [
			TrackMeta(id: "Video1", duration: 60*1000, encoding: .Video(H264Codec())),
			TrackMeta(id: "Audio1",  duration: 1*1000, encoding: .Audio)
			]
	}
	
	func GetTrackSampleManager(track: TrackUid) throws -> TrackSampleManager 
	{
		throw PopCodecError("todo")
	}
	
	
	
	static func DetectIsFormat(headerData: Data) async -> Bool 
	{
		return false
	}
}
