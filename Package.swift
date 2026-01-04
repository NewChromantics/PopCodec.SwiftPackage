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
	targets: [
		.target(
			name: "PopCodec",
			dependencies: []
		),
	]
)
