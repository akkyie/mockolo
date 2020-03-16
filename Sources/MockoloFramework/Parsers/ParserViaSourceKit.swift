//
//  Copyright (c) 2018. Uber Technologies
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import SourceKittenFramework

public class ParserViaSourceKit: SourceParsing {
    
    public init() {}
    
    public func parseProcessedDecls(_ paths: [String],
                                    semaphore: DispatchSemaphore?,
                                    queue: DispatchQueue?,
                                    completion: @escaping ([Entity], [String: [String]]?) -> ()) {
        
        if let queue = queue {
            let lock = NSLock()
            for filePath in paths {
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.generateProcessedASTs(filePath, lock: lock, completion: completion)
                    semaphore?.signal()
                }
            }
            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
        } else {
            for filePath in paths {
                generateProcessedASTs(filePath, lock: nil, completion: completion)
            }
        }
    }
    
    public func parseDecls(_ paths: [String]?,
                           isDirs: Bool,
                           exclusionSuffixes: [String]? = nil,
                           annotation: String,
                           semaphore: DispatchSemaphore?,
                           queue: DispatchQueue?,
                           completion: @escaping ([Entity], [String: [String]]?) -> ()) {
        guard !annotation.isEmpty else { return }
        guard let paths = paths else { return }
        if isDirs {
            generateASTs(dirs: paths, exclusionSuffixes: exclusionSuffixes, annotation: annotation, semaphore: semaphore, queue: queue, completion: completion)
        } else {
            generateASTs(files: paths, exclusionSuffixes: exclusionSuffixes, annotation: annotation, semaphore: semaphore, queue: queue, completion: completion)
        }
    }
    
    private func generateASTs(dirs: [String],
                              exclusionSuffixes: [String]? = nil,
                              annotation: String,
                              semaphore: DispatchSemaphore?,
                              queue: DispatchQueue?,
                              completion: @escaping ([Entity], [String: [String]]?) -> ()) {
        
        guard let annotationData = annotation.data(using: .utf8) else {
            fatalError("Annotation is invalid: \(annotation)")
        }
        if let queue = queue {
            let lock = NSLock()
            
            scanPaths(dirs) { filePath in
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.generateASTs(filePath,
                                      exclusionSuffixes: exclusionSuffixes,
                                      annotationData: annotationData,
                                      lock: lock,
                                      completion: completion)
                    semaphore?.signal()
                }
            }
            
            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
        } else {
            scanPaths(dirs) { filePath in
                generateASTs(filePath,
                             exclusionSuffixes: exclusionSuffixes,
                             annotationData: annotationData,
                             lock: nil,
                             completion: completion)
            }
        }
    }
    
    private func generateASTs(files: [String],
                              exclusionSuffixes: [String]? = nil,
                              annotation: String,
                              semaphore: DispatchSemaphore?,
                              queue: DispatchQueue?,
                              completion: @escaping ([Entity], [String: [String]]?) -> ()) {
        guard let annotationData = annotation.data(using: .utf8) else {
            fatalError("Annotation is invalid: \(annotation)")
        }
        
        if let queue = queue {
            let lock = NSLock()
            for filePath in files {
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.generateASTs(filePath,
                                      exclusionSuffixes: exclusionSuffixes,
                                      annotationData: annotationData,
                                      lock: lock,
                                      completion: completion)
                    semaphore?.signal()
                }
            }
            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
            
        } else {
            for filePath in files {
                generateASTs(filePath,
                             exclusionSuffixes: exclusionSuffixes,
                             annotationData: annotationData,
                             lock: nil,
                             completion: completion)
            }
        }
    }
    
    private func generateASTs(_ path: String,
                              exclusionSuffixes: [String]? = nil,
                              annotationData: Data,
                              lock: NSLock?,
                              completion: @escaping ([Entity], [String: [String]]?) -> ()) {
        
        guard path.shouldParse(with: exclusionSuffixes) else { return }
        guard let content = FileManager.default.contents(atPath: path) else {
            fatalError("Retrieving contents of \(path) failed")
        }
        
        do {
            var results = [Entity]()
            let topstructure = try Structure(path: path)
            for current in topstructure.substructures {
                let metadata = current.annotationMetadata(with: annotationData, in: content)
                if let node = Entity.node(with: current, filepath: path, data: content, isPrivate: current.isPrivate, isFinal: current.isFinal, metadata: metadata, processed: false) {
                    results.append(node)
                }
            }
            
            lock?.lock()
            completion(results, nil)
            lock?.unlock()
            
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    private func generateProcessedASTs(_ path: String,
                                       lock: NSLock?,
                                       completion: @escaping ([Entity], [String: [String]]) -> ()) {
        
        guard let content = FileManager.default.contents(atPath: path) else {
            fatalError("Retrieving contents of \(path) failed")
        }
        
        do {
            let topstructure = try Structure(path: path)
            let subs = topstructure.substructures
            let results = subs.compactMap { current -> Entity? in
                return Entity.node(with: current, filepath: path, data: content, isPrivate: current.isPrivate, isFinal: current.isFinal, metadata: nil, processed: true)
            }
            
            let imports = findImportLines(data: content, offset: subs.first?.offset)
            lock?.lock()
            completion(results, [path: imports])
            lock?.unlock()
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    
    func scanDecls(dirs: [String],
                   exclusionSuffixes: [String]? = nil,
                   queue: DispatchQueue?,
                   semaphore: DispatchSemaphore?,
                   completion: @escaping ([String: Val]) -> ()) {
        
        if let queue = queue {
            let lock = NSLock()
            
            scanPaths(dirs) { filePath in
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.scanDecls(filePath,
                                   exclusionSuffixes: exclusionSuffixes,
                                   lock: lock,
                                   completion: completion)
                    semaphore?.signal()
                }
            }
            
            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
        }
    }
    
    func scanDecls(_ path: String,
                   exclusionSuffixes: [String]? = nil,
                   lock: NSLock?,
                   completion: @escaping ([String: Val]) -> ()) {
        
        guard path.shouldParse(with: exclusionSuffixes) else { return }
        do {
            var results = [String: Val]()
            let topstructure = try Structure(path: path)
            for current in topstructure.substructures {
                if current.isClass, !current.name.hasPrefix("_"), !current.name.hasSuffix("Objc"), !current.name.contains("__VARIABLE_") {
                    if let attrs = current.attributeValues {
                        let hasobjc = attrs.filter{$0.contains("objc")}
                        if !hasobjc.isEmpty {
                            continue
                        }
                    }

                    results[current.name] = Val(path: path, parents: current.inheritedTypes, offset: current.range.offset, length: current.range.length, used: false)
                }
            }
            
            lock?.lock()
            completion(results)
            lock?.unlock()
            
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    func scanUsedDecls(dirs: [String],
                       exclusionSuffixes: [String]? = nil,
                       queue: DispatchQueue?,
                       semaphore: DispatchSemaphore?,
                       completion: @escaping ([String]) -> ()) {

        if let queue = queue {
            let lock = NSLock()

            scanPaths(dirs) { filePath in
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.scanUsedDecls(filePath,
                                       exclusionSuffixes: exclusionSuffixes,
                                       lock: lock,
                                       completion: completion)
                    semaphore?.signal()
                }
            }

            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
        }
    }



    func scanUsedDecls(_ path: String,
                       exclusionSuffixes: [String]? = nil,
                       lock: NSLock?,
                       completion: @escaping ([String]) -> ()) {

        guard path.shouldParse(with: exclusionSuffixes) else { return }
        guard let content = FileManager.default.contents(atPath: path) else {
            fatalError("Retrieving contents of \(path) failed")
        }
        do {
            var results = [String]()
            let topstructure = try Structure(path: path)
            for current in topstructure.substructures {

                if current.isClass {
                    results.append(contentsOf: current.inheritedTypes.map{$0.typeComponents}.flatMap{$0})
                } else if current.isExtension {
                    results.append(current.name)
                }

                // This handles members of class/extensions as well as unparsed items such as global decls, typealias rhs value, Type.self
                let ret = parseContent(content: content, start: Int(current.nameOffset + current.nameLength), end: Int(current.offset+current.length))
                results.append(contentsOf: ret)

                #if USESOURCEKIT
                if current.kind == "source.lang.swift.decl.var.global", !(current.typeName == .unknownVal || current.typeName.isEmpty || current.typeName == "Void") {
                    results.append(contentsOf: current.typeName.typeComponents)
                }
                if current.kind == "source.lang.swift.expr.call" {
                    results.append(contentsOf: current.name.typeComponents)
                }
                if current.kind == "source.lang.swift.decl.function.free", !(current.typeName == .unknownVal || current.typeName.isEmpty || current.typeName == "Void") {
                    results.append(contentsOf: current.typeName.typeComponents)
                }
                gatherUsedDecls(current, results: &results)
                #endif
            }

            lock?.lock()
            completion(results)
            lock?.unlock()

        } catch {
            fatalError(error.localizedDescription)
        }
    }


    func removeUnusedDecls(declMap: [String: Val],
                           queue: DispatchQueue?,
                           semaphore: DispatchSemaphore?,
                           completion: @escaping (Data, URL) -> ()) {
        if let queue = queue {
            let lock = NSLock()
            for (decl, val) in declMap {
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.removeUnusedDecls(val.path,
                                           decl: decl,
                                           offset: val.offset,
                                           length: val.length,
                                           lock: lock,
                                           completion: completion)
                    semaphore?.signal()
                }
            }

            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
        }
    }

    let space = UInt8(32)
    let newline = UInt8(10)
    func removeUnusedDecls(_ path: String,
                           decl: String,
                           offset: Int,
                           length: Int,
                           lock: NSLock?,
                           completion: @escaping (Data, URL) -> ()) {
        guard var content = FileManager.default.contents(atPath: path) else {
            fatalError("Retrieving contents of \(path) failed")
        }

        // TODO: remove from tests as well
        let start = Int(offset)
        let end = Int(offset + length)

        let lineIdx = content[0..<start].lastIndex(of: newline) ?? start
        let spaces = Data(repeating: space, count: end-lineIdx)
        let range = lineIdx..<end
        content.replaceSubrange(range, with: spaces)

        let url = URL(fileURLWithPath: path)

        lock?.lock()
        completion(content, url)
        lock?.unlock()
    }

    func checkUnused(_ dirs: [String],
                     unusedList: [String],
                     exclusionSuffixes: [String]?,
                     queue: DispatchQueue?,
                     semaphore: DispatchSemaphore?,
                     completion: @escaping ([String]) -> ()) {

        if let queue = queue {
            let lock = NSLock()
            scanPaths(dirs) { filepath in
                // test file path
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.checkUnused(filepath,
                                     unusedList: unusedList,
                                     exclusionSuffixes: exclusionSuffixes,
                                     lock: lock,
                                     completion: completion)
                    semaphore?.signal()
                }
            }
            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
        }
    }

    func checkUnused(_ filepath: String,
                     unusedList: [String],
                     exclusionSuffixes: [String]?,
                     lock: NSLock?,
                     completion: @escaping ([String]) -> ()) {
        guard filepath.shouldParse(with: exclusionSuffixes) else { return }
        do {
            let topstructure = try Structure(path: filepath)
            var toRemove = [String]()
            for current in topstructure.substructures {
                guard current.isClass else { continue }
                if unusedList.contains(current.name) {
                    toRemove.append(current.name)
                }
            }
            lock?.lock()
            completion(toRemove)
            lock?.unlock()
        } catch {
            log(error.localizedDescription)
        }
    }

    func updateTests(dirs: [String],
                     unusedMap: [String: Val],
                     queue: DispatchQueue?,
                     semaphore: DispatchSemaphore?,
                     completion: @escaping (Data, URL, Bool) -> ()) {
        if let queue = queue {
            let lock = NSLock()
            scanPaths(dirs) { filepath in
                // test file path
                _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
                queue.async {
                    self.updateTest(filepath,
                                    unusedMap: unusedMap,
                                    lock: lock,
                                    completion: completion)
                    semaphore?.signal()
                }
            }
            // Wait for queue to drain
            queue.sync(flags: .barrier) {}
        }
    }

    func updateTest(_ path: String,
                    unusedMap: [String: Val],
                    lock: NSLock?,
                    completion: @escaping (Data, URL, Bool) -> ()) {

        guard path.hasSuffix("Tests.swift") || path.hasSuffix("Test.swift") else { return }

        guard var content = FileManager.default.contents(atPath: path) else {
            fatalError("Retrieving contents of \(path) failed")
        }

        do {
            let topstructure = try Structure(path: path)
            var toDelete = [String: (Int64, Int64)]()
            var deleteCount = 0
            var declsInFile = 0
            for current in topstructure.substructures {
                guard current.isClass else { continue }
                var testname = current.name
                if testname.hasSuffix("Tests") {
                    testname = String(testname.dropLast("Tests".count))
                } else if testname.hasSuffix("Test") {
                    testname = String(testname.dropLast("Test".count))
                }
                declsInFile += 1

                if let _ = unusedMap[testname] {
                    // 1. if it's the test name
                    //if v.path.module == path.module { // TODO: need this?
                    toDelete[testname] = (current.range.offset, current.range.length)
                    deleteCount += 1
                    print("DELETE", current.name, testname)
                    //}
                } else {
                    print("IN body: ", current.name, testname)

                    // 2. if it's within the test body as var decls, func bodies, exprs, return val, etc.
                    // Then remove the whole function or class using it
                    // let x = UnusedClass()  <--- removing this requires removing occurrences of x (or expr itself) or replacing it with a subsitution everywhere.
                    // let x: UnusedClass     <--- removing this requires above and also assignment to x
                    // updateBody(current, unusedMap: unusedMap, content: &content)
                }
            }

            let shouldDelete = declsInFile == deleteCount

            if !shouldDelete {
                for (k, v) in toDelete {
                    replace(&content, offset: v.0, length: v.1, with: space)
                }
            }

            let url = URL(fileURLWithPath: path)
            lock?.lock()
            completion(content, url, shouldDelete)
            lock?.unlock()
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    private func replace(_ content: inout Data, offset: Int64, length: Int64, with another: UInt8) {
        let start = Int(offset)
        let end = Int(length)
        if start > 0, end > start {
            let anotherData = Data(repeating: another, count: end-start)
            let range = start..<end
            content.replaceSubrange(range, with: anotherData)
        }
    }

    private func updateBody(_ current: Structure,
                            unusedMap: [String: Val],
                            content: inout Data) {
        for sub in current.substructures {
            let types = [sub.name.typeComponents, sub.typeName.typeComponents].flatMap{$0}
            for t in types {
                if unusedMap[t] != nil {
                    print("FOUND", t, current.name)
                    replace(&content, offset: sub.range.offset, length: sub.range.length, with: space)
                }
            }
            updateBody(sub, unusedMap: unusedMap, content: &content)
        }
    }

    private func parseContent(content: Data, start: Int, end: Int) -> [String] {
        guard start > 0, end > start else { return [] }
        let range = start..<end
        let subdata = content.subdata(in: range)
        if let str = String(data: subdata, encoding: .utf8) {
            var buffer = [String]()
            let comps = str.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter{!$0.isEmpty}
            for c in comps {
                buffer.append(contentsOf: c.typeComponents)
            }
            return buffer
        }
        return []
    }


    private func gatherUsedDecls(_ current: Structure, results: inout [String]) {
        for sub in current.substructures {
            if sub.kind == SwiftDeclarationKind.genericTypeParam.rawValue {
                results.append(contentsOf: sub.name.typeComponents)
            }

            if sub.kind == "source.lang.swift.decl.var.parameter" {
                results.append(contentsOf: sub.typeName.typeComponents)
            }

            if sub.kind == "source.lang.swift.expr.call" {
                results.append(contentsOf: sub.name.typeComponents)
            }

            if sub.isVariable || sub.kind == "source.lang.swift.decl.var.local", sub.typeName != .unknownVal {
                results.append(contentsOf: sub.typeName.typeComponents)
            }

            if sub.isMethod || sub.kind == "source.lang.swift.decl.function.method.class", !(sub.typeName == .unknownVal || sub.typeName.isEmpty || sub.typeName == "Void") {
                results.append(contentsOf: sub.typeName.typeComponents)
            }

            gatherUsedDecls(sub, results: &results)
        }
    }
}


