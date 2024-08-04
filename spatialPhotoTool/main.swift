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

extension Collection {
	func unfoldSubSequences(limitedTo maxLength: Int) -> UnfoldSequence<SubSequence,Index> {
		sequence(state: startIndex) { start in
			guard start < self.endIndex else { return nil }
			let end = self.index(start, offsetBy: maxLength, limitedBy: self.endIndex) ?? self.endIndex
			defer { start = end }
			return self[start..<end]
		}
	}
}

struct SpatialPhotoTool: ParsableCommand {
	@Argument var files: [String] = []
	@Option(name: .customLong("hfov"), help: "Horizontal field-of-view (in degrees).")
	var hFOV: Double?
	@Option(name: [.short, .customLong("disparityAdjustment")], help: "Disparity adjustment, -1.0 to 1.0.")
	var disparityAdjustment: Double?
	@Option(name: [.short, .customLong("baseline")], help: "Baseline (IPD) of lenses in mm.")
	var baseline: Double?
	@Option(name: [.short, .customLong("sensorWidth")], help: "Width of the camera sensor/film (in mm, i.e. 36mm for a full frame camera or 23.5 for a Sony APS-C camera).")
	var sensorWidth: Double?
	@Option(name: [.short, .customLong("focalLength")], help: "Focal length of the lens (in mm).")
	var focalLength: Int?
	@Flag(name: [.short, .customLong("pairs")], help: "Convert images in pairs: <left1> <right1> .. <leftN> <rightN>.")
	var pairs = false


	static let configuration = CommandConfiguration(commandName: "spatialPhotoTool")

	mutating func run() throws {
		if hFOV != nil && (sensorWidth != nil || focalLength != nil) {
			print("WARNING: using hFOV, not focalLength")
		}
		if (sensorWidth != nil && focalLength == nil) || (sensorWidth == nil && focalLength != nil) {
			print("WARNING: sensorWidth and focalLength must both be specified, ignoring")
		}
		if hFOV == nil, let sensorWidth = sensorWidth, let focalLength = focalLength {
			hFOV = 2 * 180 / Double.pi * atan(sensorWidth / (2 * Double(focalLength)))
			print("Calculated hFOV = \(hFOV ?? 0)")
		}

		if pairs {
			if files.count % 2 != 0 {
				print("files are not pairs of images!")
				return
			}
			for filePair in files.unfoldSubSequences(limitedTo: 2) {
				guard let left = filePair.first else { continue }
				guard let right = filePair.last else { continue }
				guard FileManager.default.fileExists(atPath: left) else {
					print("Can't open \(left)")
					continue
				}
				guard FileManager.default.fileExists(atPath: right) else {
					print("Can't open \(right)")
					continue
				}

				let leftUrl = URL(fileURLWithPath: left)
				let rightUrl = URL(fileURLWithPath: right)
				print("Converting image pair: left: \(leftUrl.lastPathComponent) right: \(rightUrl.lastPathComponent)")
				convertPair(leftUrl, rightUrl)
			}
		} else {
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
	}

	/// the QooCam writes the date in UTC, so adjust it to the local time
	private func offsetDate(_ dateString: String) -> String {
		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

		guard let date = dateFormatter.date(from: dateString) else { return dateString }

		let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: date))
		return dateFormatter.string(from: (date + offset))
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

		createSpatialImage(URL(fileURLWithPath: url.deletingPathExtension().path(percentEncoded: false) + ".heic"), left: images[0], right: images[1], leftMetadata: properties, rightMetadata: properties, hFOV: hFOV ?? 48.0, baseline: baseline ?? 75.0)
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

					if let originalDate = tiffProperties[kCGImagePropertyTIFFDateTime] as? String {
						tiffProperties.updateValue(offsetDate(originalDate), forKey: kCGImagePropertyTIFFDateTime)
					}

					properties.updateValue(tiffProperties as CFDictionary, forKey: kCGImagePropertyTIFFDictionary)
				}

				if var exifProperties = properties[kCGImagePropertyExifDictionary] as? Dictionary<CFString, Any> {
					if let originalDate = exifProperties[kCGImagePropertyExifDateTimeOriginal] as? String {
						exifProperties.updateValue(offsetDate(originalDate), forKey: kCGImagePropertyExifDateTimeOriginal)
					}
					if let originalDate = exifProperties[kCGImagePropertyExifDateTimeDigitized] as? String {
						exifProperties.updateValue(offsetDate(originalDate), forKey: kCGImagePropertyExifDateTimeDigitized)
					}
					properties.updateValue(exifProperties as CFDictionary, forKey: kCGImagePropertyExifDictionary)
				}
			}
		}

		createSpatialImage(URL(fileURLWithPath: url.deletingPathExtension().path(percentEncoded: false) + ".heic"), left: left, right: right, leftMetadata: properties as CFDictionary, rightMetadata: properties as CFDictionary, hFOV: hFOV ?? 66.0, baseline: baseline ?? 65.0)
	}

	func convertPair(_ left: URL, _ right: URL) {
		guard let leftImageSource = CGImageSourceCreateWithURL(left as CFURL, nil) else {
			print("Can't open image \(left.lastPathComponent)")
			return
		}
		guard let rightImageSource = CGImageSourceCreateWithURL(right as CFURL, nil) else {
			print("Can't open image \(right.lastPathComponent)")
			return
		}

		let leftImageCount = CGImageSourceGetCount(leftImageSource)
		guard leftImageCount == 1 else {
			print("Unexpected number of images in \(left.lastPathComponent): \(leftImageCount)")
			return
		}
		let rightImageCount = CGImageSourceGetCount(rightImageSource)
		guard rightImageCount == 1 else {
			print("Unexpected number of images in \(right.lastPathComponent): \(rightImageCount)")
			return
		}

		guard let leftImage = CGImageSourceCreateImageAtIndex(leftImageSource, 0, nil) else {
			print("Can't load image \(left.lastPathComponent)")
			return
		}
		guard let rightImage = CGImageSourceCreateImageAtIndex(rightImageSource, 0, nil) else {
			print("Can't load image \(right.lastPathComponent)")
			return
		}

		// load EXIF data to copy to destination images
		guard let leftProperties = CGImageSourceCopyPropertiesAtIndex(leftImageSource, 0, nil) else {
			print("Unable to load metadata for \(left.lastPathComponent)")
			return
		}
		guard let rightProperties = CGImageSourceCopyPropertiesAtIndex(rightImageSource, 0, nil) else {
			print("Unable to load metadata for \(right.lastPathComponent)")
			return
		}

		createSpatialImage(URL(fileURLWithPath: left.deletingPathExtension().path(percentEncoded: false) + ".heic"), left: leftImage, right: rightImage, leftMetadata: leftProperties, rightMetadata: rightProperties, hFOV: hFOV ?? 54.12, baseline: baseline ?? 65.0)
	}

	func propertiesDictionary(isLeft: Bool, disparityAdjustment: Double?, position: [Double], intrinsics: [CGFloat], metadata: CFDictionary) -> [CFString: Any] {
		let rotationMatrix: [CGFloat] = [
			1, 0, 0,
			0, 1, 0,
			0, 0, 1
		]

		let encodedDisparityAdjustment = Int((disparityAdjustment ?? 0) * 1e4)

		var properties = (metadata as? Dictionary<String, Any>) ?? [String: Any]()

		properties[kCGImagePropertyGroups as String] = [
			kCGImagePropertyGroupIndex: 0,
			kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
			(isLeft ? kCGImagePropertyGroupImageIsLeftImage : kCGImagePropertyGroupImageIsRightImage): true,
			kCGImagePropertyGroupImageDisparityAdjustment: encodedDisparityAdjustment,
		]
		properties[kCGImagePropertyHEIFDictionary as String] = [
			kIIOMetadata_CameraModelKey: [
				kIIOCameraModel_Intrinsics: intrinsics as CFArray,
				kIIOCameraModel_ModelType: kIIOCameraModelType_SimplifiedPinhole,
			],
			kIIOMetadata_CameraExtrinsicsKey: [
				kIIOCameraExtrinsics_CoordinateSystemID: 0 as CGFloat,
				kIIOCameraExtrinsics_Position: position as CFArray,
				kIIOCameraExtrinsics_Rotation: rotationMatrix as CFArray,
			]
		]
		properties[kCGImagePropertyHasAlpha as String] = false

		return properties as [CFString: Any]
	}

	func createSpatialImage(_ url: URL, left: CGImage, right: CGImage, leftMetadata: CFDictionary, rightMetadata: CFDictionary, hFOV: Double, baseline: Double) {
		guard left.width == right.width && left.height == right.height else {
			print("Image sizes are mismatched: \(url.lastPathComponent)")
			return
		}
		print("Saving images to \(url.path(percentEncoded: false))")
		print("Using hFOV=\(hFOV)")
		print("Using baseline=\(baseline)")
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

		CGImageDestinationAddImage(destination, left, propertiesDictionary(isLeft: true, disparityAdjustment: disparityAdjustment, position: [0, 0, 0], intrinsics: cameraIntrinsics, metadata: leftMetadata) as CFDictionary)
		let baselineInMeters = baseline / 1000.0
		CGImageDestinationAddImage(destination, right, propertiesDictionary(isLeft: false, disparityAdjustment: disparityAdjustment, position: [baselineInMeters, 0, 0], intrinsics: cameraIntrinsics, metadata: rightMetadata) as CFDictionary)
		CGImageDestinationFinalize(destination)
	}
}

SpatialPhotoTool.main()
