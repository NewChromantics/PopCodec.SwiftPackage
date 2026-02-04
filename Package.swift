// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.


import PackageDescription



let package = Package(
	name: "PopCodec",
	
	platforms: [
		.iOS(.v15),
		//	14 for VTDecompressionSessionCreate
		.macOS(.v14)	
	],
	

	products: [
		.library(
			name: "PopCodec",
			targets: [
				"PopCodec"
			]),
	],
	
	dependencies: [
		.package(url: "https://github.com/NewChromantics/PopCommon.SwiftPackage.git", branch: "main"),
		.package(url: "https://github.com/mattmassicotte/Queue.git", branch: "main")
	],
		
	targets: [
		.target(
			name: "PopCodec",
			dependencies: [
				.product(name: "PopCommon", package: "PopCommon.SwiftPackage"),
				.product(name: "Queue", package: "Queue")
			]
		),
	]
)
