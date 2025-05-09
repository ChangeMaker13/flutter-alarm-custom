# iOS Setup

## Step 1
First, open your project in Xcode, select your Runner and then Signing & Capabilities tab. In the Background Modes section, make sure to enable:
- [x] Audio, AirPlay, and Picture in Picture
- [x] Background fetch

![bg-mode](https://github.com/gdelataillade/alarm/assets/32983806/13716845-5fb0-4fef-a762-292c374840bb)

It should add this in your Info.plist code:
```XML
	<key>UIBackgroundModes</key>
	<array>
		<string>fetch</string>
		<string>audio</string>
	</array>
```

This allows the app to check alarms in the background.

## Step 2
Then, open your Info.plist and add the key `Permitted background task scheduler identifiers`, with the item `com.gdelataillade.fetch` inside.

![info-plist](https://github.com/gdelataillade/alarm/assets/32983806/caa1060e-c046-4eae-b1ea-5f3145b8fed4)


It should add this in your Info.plist code:
```XML
	<key>BGTaskSchedulerPermittedIdentifiers</key>
	<array>
		<string>com.gdelataillade.fetch</string>
	</array>
```

This authorizes the app to run background tasks using the specified identifier.

## Step 3
Open your AppDelegate and add the following imports:

```Swift
import UserNotifications
import alarm
```

Finally, add the following to your `application(_:didFinishLaunchingWithOptions:)` method:

```Swift
if #available(iOS 10.0, *) {
  UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
}
SwiftAlarmPlugin.registerBackgroundTasks()
```

![app-delegate](https://github.com/gdelataillade/alarm/assets/32983806/fcc00495-ecf0-4db3-9964-89bbedf577a7)

This configures the app to manage foreground notifications and setup background tasks.

## Step 4

Update your iOS minimum deployment target in your Podfile:

```Ruby
platform :ios, '13.0'
```

and also on Xcode:

![CleanShot 2025-03-30 at 18 59 41](https://github.com/user-attachments/assets/92dfd652-eaa8-4a62-8c0c-a5573a98134d)

This should update your `IPHONEOS_DEPLOYMENT_TARGET` in your `project.pbxproj`.

⚠️ Don't forget to run `flutter pub get` and `pod install --repo-update` to update your pods.
