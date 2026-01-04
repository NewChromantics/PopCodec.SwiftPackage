import Combine

//	make it easier to subscribe to observable objects
public protocol ObservableSubscribable : ObservableObject
{
	var subscriberCancellables : [AnyCancellable]	{get set}
}

public extension ObservableSubscribable
{
	func Subscribe(onChanged:@escaping()->Void)
	{
		let cancellable = self.objectWillChange.sink
		{
			myOwnValue in
			onChanged()
		}
		subscriberCancellables.append(cancellable)
	}
}
