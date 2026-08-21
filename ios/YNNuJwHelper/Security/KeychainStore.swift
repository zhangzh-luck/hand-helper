import Foundation
import Security
enum KeychainStore { static func save(_ value:String,key:String)throws { let data=Data(value.utf8);SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrAccount:key] as CFDictionary);let status=SecItemAdd([kSecClass:kSecClassGenericPassword,kSecAttrAccount:key,kSecValueData:data] as CFDictionary,nil);guard status==errSecSuccess else{throw NSError(domain:"Keychain",code:Int(status))} } }
