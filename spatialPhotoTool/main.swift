//
//  main.swift
//  spatialPhotoTool
//
//  Created by Scott Jann on 5/10/24.
//

import Foundation
import CoreImage
import UniformTypeIdentifiers
import ArgumentParser

let mpoheader = Data([0xFF, 0xD8, 0xFF, 0xE1] as [UInt8])

struct SpatialPhotoTool: ParsableCommand {
	@Argument var files: [String] = []
	@Option(name: .customLong("hfov"), help: "Horizontal field-of-view (in degrees).")
	var hFOV: Double?

	static let configuration = CommandConfiguration(commandName: "spatialPhotoTool")

	func run() throws {
		for file in files {
			guard FileManager.default.fileExists(atPath: file) else {
				print("Can't open \(file)")
				continue
			}

			let url = URL(fileURLWithPath: file)
			switch url.pathExtension.lowercased() {
			case "mpo":
				print("Converting multi-picture-object image: \(url.lastPathComponent)")
				convertMPO(url)
			case "jpg", "jpeg", "png", "heic":
				print("Converting side-by-side image: \(url.lastPathComponent)")
				convertSBS(url)
			default:
				print("Unknown file specified: \(url.lastPathComponent)")
			}
		}
	}

	private func convertMPO(_ url: URL) {
		guard let data = try? Data(contentsOf: url) else {
			print("Can't read from \(url.lastPathComponent)")
			return
		}

		var markerLocations = [Int]()
		var markerOffset = data.range(of: mpoheader, options:[], in: 0..<data.count)

		while let offset = markerOffset {
			markerLocations.append(offset.lowerBound)
			markerOffset = data.range(of: mpoheader, options:[], in: offset.upperBound..<data.count)
		}

		guard markerLocations.count > 0 else {
			print("Could not find images in \(url.lastPathComponent)")
			return
		}

		print("Found \(markerLocations.count) image\(markerLocations.count == 1 ? "" : "s") in \(url.lastPathComponent)")

		var images = [CGImage]()
		var properties: CFDictionary?
		for (index, imageOffset) in markerLocations.enumerated() {
			let endOffset = index == markerLocations.count - 1 ? data.count : markerLocations[index + 1]
			let imageData = data.subdata(in: imageOffset..<endOffset)

			guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
				print("Can't open image \(url.lastPathComponent)")
				return
			}

			let imageCount = CGImageSourceGetCount(imageSource)
			guard imageCount == 1 else {
				print("Unexpected number of images in \(url.lastPathComponent): \(imageCount)")
				return
			}

			guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
				print("Can't load image \(url.lastPathComponent)")
				return
			}

			if properties == nil {
				// load EXIF data to copy to destination images
				properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
			}
			images.append(image)
		}

		guard let properties = properties else {
			print("Unable to load metadata for \(url.lastPathComponent)")
			return
		}

		guard images.count == 2 else {
			print("Unexpected number of images in \(url.lastPathComponent) MPO: \(images.count)")
			return
		}

		createSpatialImage(URL(fileURLWithPath: url.deletingPathExtension().path(percentEncoded: false) + ".heic"), left: images[0], right: images[1], metadata: properties, hFOV: hFOV ?? 48.0)
	}

	private func convertSBS(_ url: URL) {
		guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
			print("Can't open image \(url.lastPathComponent)")
			return
		}

		let imageCount = CGImageSourceGetCount(imageSource)
		guard imageCount == 1 else {
			print("Unexpected number of images in \(url.lastPathComponent): \(imageCount)")
			return
		}

		guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
			print("Can't load image \(url.lastPathComponent)")
			return
		}

		// load EXIF data to copy to destination images
		guard var properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as Dictionary? else {
			print("Unable to load metadata for \(url.lastPathComponent)")
			return
		}

		let leftRect = CGRect(x: 0, y: 0, width: image.width / 2, height: image.height)
		let rightRect = CGRect(x: image.width / 2, y: 0, width: image.width / 2, height: image.height)

		guard let left = image.cropping(to: leftRect), let right = image.cropping(to: rightRect) else {
			print("Can't split image \(url.lastPathComponent)")
			return
		}

		// the EXIF data for QooCam images is missing the Camera Make/Model, so add it
		if let userData = properties[kCGImagePropertyExifDictionary]?[kCGImagePropertyExifUserComment] as? String {
			if userData.hasPrefix("QooCam+EGO") {
				if var tiffProperties = properties[kCGImagePropertyTIFFDictionary] as? Dictionary<CFString, Any> {
					print("Adding QooCam EGO Camera info...")
					tiffProperties.updateValue("Kandao", forKey: kCGImagePropertyTIFFMake)
					tiffProperties.updateValue("QooCam EGO", forKey: kCGImagePropertyTIFFModel)
					properties.updateValue(tiffProperties as CFDictionary, forKey: kCGImagePropertyTIFFDictionary)
				}
			}
		}

		createSpatialImage(URL(fileURLWithPath: url.deletingPathExtension().path(percentEncoded: false) + ".heic"), left: left, right: right, metadata: properties as CFDictionary, hFOV: hFOV ?? 66.0)
	}

	func createSpatialImage(_ url: URL, left: CGImage, right: CGImage, metadata: CFDictionary, hFOV: Double) {
		guard left.width == right.width && left.height == right.height else {
			print("Image sizes are mismatched: \(url.lastPathComponent)")
			return
		}
		print("Saving images to \(url.path(percentEncoded: false))")
		print("Using hFOV=\(hFOV)")
		print("image size is \(left.width)x\(left.height) + \(right.width)x\(right.height)")

		let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 2, nil)!
		let imageWidth = CGFloat(left.width)
		let imageHeight = CGFloat(left.height)
		let fovHorizontalDegrees: CGFloat = hFOV
		let fovHorizontalRadians = fovHorizontalDegrees * (.pi / 180)
		let focalLengthPixels = 0.5 * imageWidth / tan(0.5 * fovHorizontalRadians)

		let cameraIntrinsics: [CGFloat] = [
			focalLengthPixels, 0, imageWidth / 2,
			0, focalLengthPixels, imageHeight / 2,
			0, 0, 1
		]

		let rotationMatrix: [CGFloat] = [
			1, 0, 0,
			0, 1, 0,
			0, 0, 1
		]

		let positionMatrix: [CGFloat] = [ 0, 0, 0 ]

		guard var properties = metadata as? Dictionary<String, Any> else {
			return
		}
		properties[kCGImagePropertyGroups as String] = [
			kCGImagePropertyGroupIndex: 0,
			kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
			kCGImagePropertyGroupImageIndexLeft: 0,
			kCGImagePropertyGroupImageIndexRight: 1,
		]
		properties[kCGImagePropertyHEIFDictionary as String] = [
			kIIOMetadata_CameraModelKey: [
				kIIOCameraModel_Intrinsics: cameraIntrinsics as CFArray,
			],
			kIIOMetadata_CameraExtrinsicsKey: [
				kIIOCameraExtrinsics_CoordinateSystemID: 0 as CGFloat,
				kIIOCameraExtrinsics_Position: positionMatrix as CFArray,
				kIIOCameraExtrinsics_Rotation: rotationMatrix as CFArray,
			]
		]

		CGImageDestinationAddImage(destination, left, properties as CFDictionary)
		CGImageDestinationAddImage(destination, right, properties as CFDictionary)
		CGImageDestinationFinalize(destination)
	}
}

SpatialPhotoTool.main()
