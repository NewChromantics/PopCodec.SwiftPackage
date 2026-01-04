import CoreMedia

public typealias Millisecond = UInt64




extension CMTime
{
	init(millisecond:Millisecond)
	{
		self.init(value: CMTimeValue(millisecond), timescale: 1000)
	}
	
	nonisolated var milliseconds : Millisecond
	{
		let secs : Float64 = CMTimeGetSeconds(self)
		let msFloat = secs * 1000
		//	round up, not down to fix rounding errors
		let ms = floor(msFloat+0.5)
		return Millisecond(ms)
	}
}
/*
 @Test func CMTimeMillisecondConversion() throws 
 {
 //	4087 specifically was failing
 let inputMs = Millisecond(4087)
 let time = CMTime(millisecond: inputMs)
 let outputMs = time.milliseconds
 if inputMs != outputMs
 {
 throw AppError("CMTime millisecond conversion failed; \(inputMs) -> \(time) -> \(outputMs)")
 }
 }
 */
