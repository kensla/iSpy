/*
 * iSpy - Bishop Fox iOS hacking/hooking/sandboxing framework.
 */

#include <stack>
#include <fcntl.h>
#include <stdio.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <unistd.h>
#include <string.h>
#include <dirent.h>
#include <stdbool.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <objc/objc.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#import  <Security/Security.h>
#import  <Security/SecCertificate.h>
#include <CFNetwork/CFNetwork.h>
#include <CFNetwork/CFProxySupport.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFStream.h>
#import  <Foundation/NSJSONSerialization.h>
#include "iSpy.common.h"
#include "iSpy.instance.h"
#include "iSpy.class.h"
#include "hooks_C_system_calls.h"
#include "hooks_CoreFoundation.h"
#import "HTTPKit/HTTP.h"
#import "HTTPKit/mongoose.h"
#include <dlfcn.h>
#include <mach-o/nlist.h>
#include <semaphore.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "iSpy.rpc.h"

/* Underscore.js requires the use of eval :( */
// static NSString *CSP = @"default-src *; script-src 'self' 'unsafe-eval';";

/* Whitelist of static content we'll serve */
static NSDictionary *STATIC_CONTENT = @{
    @"js": @"text/javascript",
    @"css": @"text/css",
    @"png": @"image/png",
    @"jpg": @"image/jpeg",
    @"jpeg": @"image/jpeg",
    @"ico": @"image/ico",
    @"gif": @"image/gif",
    @"svg": @"image/svg+xml",
    @"tff": @"application/x-font-ttf",
    @"eot": @"application/vnd.ms-fontobject",
    @"woff": @"application/x-font-woff",
    @"otf": @"application/x-font-otf",
};

static struct mg_connection *globalMsgSendWebSocketPtr = NULL; // mg_connection is (was) a private struct in HTTPKit

@implementation iSpyServer

-(void)configureWebServer {
    [self setHttp:NULL];
    [self setJsonRpc:NULL];
    [self setPlist: NULL];
    [self setHttp:[[HTTP alloc] init]];
    [self setJsonRpc:[[HTTP alloc] init]];
    [[self http] setEnableDirListing:NO];
    [[self http] setPublicDir:@"/var/www/iSpy"];
    [[self jsonRpc] setEnableKeepAlive:YES];
    [self setPlist: [[NSMutableDictionary alloc] initWithContentsOfFile:@PREFERENCEFILE]];
}

-(id)init {
    [super init];
    [self configureWebServer];
    return self;
}

-(void)bounceWebServer {
    ispy_log_debug(LOG_HTTP, "Stopping mongoose...");
    mg_stop([[self http] __ctx]);
    sleep(2);
    ispy_log_debug(LOG_HTTP, "Starting webserver...");
    [self startWebServices];
    ispy_log_debug(LOG_HTTP, "Done.");
}

-(int) getListenPortFor:(NSString *) key
       fallbackTo:(int) fallback
{
    int lport = [[self.plist objectForKey:key] intValue];
    if (lport <= 0 || 65535 <= lport) {
        ispy_log_warning(LOG_HTTP, "Invalid listen port (%d); fallback to %d", lport, fallback);
        lport = fallback;
    }
    if (lport <= 1024) {
        ispy_log_warning(LOG_HTTP, "%d is a priviledged port, this is most likely not going to work!", lport);
    }
    return lport;
}

-(BOOL) startWebServices {
    // Initialize the iSpy web service
    BOOL web, ws;

    int web_lport = [self getListenPortFor:@"settings_webServerPort" fallbackTo:31337];
    ispy_log_debug(LOG_HTTP, "Binding web server to port: %d", web_lport);
    web = [[self http] listenOnPort:web_lport onError:^(id reason) {
        ispy_log_error(LOG_HTTP, "Failed to bind web server: %s", [reason UTF8String]);
    }];

    int rpc_lport = [self getListenPortFor:@"settings_jsonRpcPort" fallbackTo:31338];
    ispy_log_debug(LOG_HTTP, "Binding json-rpc to port: %d", rpc_lport);
    ws = [[self jsonRpc] listenOnPort:rpc_lport onError:^(id reason) {
        ispy_log_error(LOG_HTTP, "Failed to bind json-rpc server: %s", [reason UTF8String]);
    }];

    if(!web || !ws) {
        ispy_log_error(LOG_HTTP, "Failed to bind one or more sockets, abandon ship!");
        return false;
    }

    /*
     * App Handler
     *
     * Since iSpy is basically remote code execution as a feature, it seems
     * prudent to add as many security headers as possible. This is the only page.
     */
    [[self http] handleGET:@"/"
        with:^(iSpy_HTTPConnection *connection) {
            NSString *pathToIndex = [NSString stringWithFormat:@"%@/pages/index.html", [[self http] publicDir]];
            NSData *data = [NSData dataWithContentsOfFile:pathToIndex];
            ispy_log_info(LOG_HTTP, "[GET] Page -> %s", [pathToIndex UTF8String]);
            [connection setResponseHeader:@"X-XSS-Protection" to:@"1; mode=block"];
            [connection setResponseHeader:@"X-Frame-Options" to:@"DENY"];
            [connection setResponseHeader:@"X-Content-Type-Options" to:@"nosniff"];
            // [connection setResponseHeader:@"Content-Security-Policy" to:CSP];
            [connection setResponseHeader:@"Content-Type" to:@"text/html"];
            [connection setResponseHeader:@"Content-Length" to:[NSString stringWithFormat:@"%d", [data length]]];
            [connection writeData:data];
            return nil;
    }];

    /*
     * Static Content Handler
     *
     * Handler for all static content: CSS, JavaScript, images, etc (but notably not HTML)
     * It's very important to get the content-type correct since we set the nosniff header
     */
    [[self http] handleGET:@"/static/*/*"
        with:^(iSpy_HTTPConnection *connection, NSString *folder, NSString *fname) {
            [connection setResponseHeader:@"X-XSS-Protection" to:@"1; mode=block"];
            [connection setResponseHeader:@"X-Frame-Options" to:@"DENY"];
            [connection setResponseHeader:@"X-Content-Type-Options" to:@"nosniff"];

            NSString *contentType = [STATIC_CONTENT valueForKey:[fname pathExtension]];
            if(!contentType) {
                [connection setResponseHeader:@"Content-Type" to:@"x/unknown"];
                ispy_log_warning(LOG_HTTP, "Could not determine content-type of static resource: %s", [fname UTF8String]);
            } else {
                /* We only write the data if we know the content-type */
                NSString *pathToStaticFile = [NSString stringWithFormat:@"%@/static/%@/%@", [[self http] publicDir], folder, fname];
                NSData *data = [NSData dataWithContentsOfFile:pathToStaticFile];
                [connection setResponseHeader:@"Content-Type" to:contentType];
                [connection setResponseHeader:@"Content-Length" to:[NSString stringWithFormat:@"%d", [data length]]];
                [connection writeData:data];
            }
            return nil;
    }];

    /*
     * Four-oh-Four Handler
     *
     * Any GET that's not a handled is a 404
     */
    [[self http] handleGET:@"/*"
        with:^(iSpy_HTTPConnection *connection, NSString *name) {
            NSString *pathToIndex = [NSString stringWithFormat:@"%@/pages/404.html", [[self http] publicDir]];
            NSData *data = [NSData dataWithContentsOfFile:pathToIndex];
            ispy_log_info(LOG_HTTP, "[404] -> %s", [name UTF8String]);
            [connection setResponseHeader:@"X-XSS-Protection" to:@"1; mode=block"];
            [connection setResponseHeader:@"X-Frame-Options" to:@"DENY"];
            [connection setResponseHeader:@"X-Content-Type-Options" to:@"nosniff"];
            [connection setResponseHeader:@"Content-Type" to:@"text/html"];
            [connection setResponseHeader:@"Content-Length" to:[NSString stringWithFormat:@"%d", [data length]]];
            [connection writeData:data];
            return nil;
    }];


    /*
     * POST JSON-RPC handler
     *
     * Dispatches RPC methods and returns a response.
     */
    [[self http] handlePOST:@"/rpc" with:^(iSpy_HTTPConnection *connection) {
        // Dispatch the method handler
        NSDictionary *responseDict = [self dispatchRPCRequest:connection.requestBody];

        // If there's a resposne, convert it from NSDictionary into a JSON string and send it back to the caller.
        if(responseDict) {
            // first convert the user-supplied JSON-RPC request into NSDATA
            NSData *RPCRequest = [connection.requestBody dataUsingEncoding:NSUTF8StringEncoding];
            if( ! RPCRequest) {
                ispy_log_debug(LOG_HTTP, "ERROR: Could not convert websocket payload into NSData");
                return nil;
            }
            
            // create a dictionary from the JSON-RPC request
            NSDictionary *RPCDictionary = [NSJSONSerialization JSONObjectWithData:RPCRequest options:kNilOptions error:nil];
            if(!RPCDictionary) {
                ispy_log_debug(LOG_HTTP, "ERROR: Invalid RPC request, couldn't deserialze the JSON data.");
                return nil;
            }

            // did the user request a response? If so, send one.
            if([RPCDictionary objectForKey:@"responseId"]) {
                NSDictionary *finalResponse = @{ 
                    @"messageType":@"response",
                    @"responseId":[RPCDictionary objectForKey:@"responseId"],
                    @"responseData": responseDict
                };
                NSData *JSONData = [NSJSONSerialization dataWithJSONObject:finalResponse options:0 error:NULL];
                if(JSONData) {
                    NSString *JSONString = [[NSString alloc] initWithData:JSONData encoding:NSUTF8StringEncoding];
                    if(JSONString) {
                        // Set the correct JSON Content-Type, as specified by RFC4627 (http://www.ietf.org/rfc/rfc4627.txt)
                        [connection setResponseHeader:@"Content-Type" to:@"application/json"];
                        [connection writeString:JSONString];
                    }
                }
            }
        }

        // all done.
        return nil;
    }];           


    /*
     * WebSocket JSON-RPC handler
     *
     * It's important to check the request's "origin" header to prevent any cross-domain
     * websocket requests from accessing the JSON-RPC interface (which would end badly).
     * FIXME.
     */
    [[self jsonRpc] handleWebSocket:^id (iSpy_HTTPConnection *connection) {
        if(!connection.isOpen) {
            ispy_log_info(LOG_HTTP, "Closed web socket.");
            globalMsgSendWebSocketPtr = NULL;
            return nil;
        }

        // make sure that this pointer is correct - it's needed by the obj_msgSend logging code
        globalMsgSendWebSocketPtr = [connection connectionPtr];

        // grab the JSON request from the client
        NSString *JSONString = connection.requestBody;  
        if( ! JSONString) {
            ispy_log_debug(LOG_HTTP, "ERROR: there was no body in the websocket request");
            return nil;
        }

        // Dispatch the RPC request and receive the response, if any
        NSDictionary *responseDict = [self dispatchRPCRequest:JSONString];
        
        // If there's a response, convert it from NSDictionary into a JSON string and send it back to the caller.
        if(responseDict) {
            NSData *RPCRequest = [connection.requestBody dataUsingEncoding:NSUTF8StringEncoding];
            if( ! RPCRequest) {
                ispy_log_debug(LOG_HTTP, "ERROR: Could not convert websocket payload into NSData");
                return nil;
            }
            
            // create a dictionary from the JSON request
            NSDictionary *RPCDictionary = [NSJSONSerialization JSONObjectWithData:RPCRequest options:kNilOptions error:nil];
            if(!RPCDictionary) {
                ispy_log_debug(LOG_HTTP, "ERROR: invalid RPC request, couldn't deserialze the JSON data.");
                return nil;
            }

            // Now we can check: did the user actually ask for a response?
            if([RPCDictionary objectForKey:@"responseId"]) {
                NSDictionary *finalResponse = @{ 
                    @"messageType":@"response",
                    @"responseId":[RPCDictionary objectForKey:@"responseId"],
                    @"responseData": responseDict
                };
                NSData *JSONData = [NSJSONSerialization dataWithJSONObject:finalResponse options:0 error:NULL];
                if(JSONData) {
                    NSString *JSONString = [[NSString alloc] initWithData:JSONData encoding:NSUTF8StringEncoding];
                    if(JSONString) {
                        bf_websocket_write([JSONString UTF8String]);
                    }
                }
            }
        }
        
        return nil;
    }];

    ispy_log_debug(LOG_HTTP, "Successfully initialized web server on %d and rpc server on %d", web_lport, rpc_lport);
    return true;
}

// Pass this an NSString containing a JSON-RPC request. 
// It will do sanity/security checks, then dispatch the method, then return an NSDictionary as a return value.
-(NSDictionary *)dispatchRPCRequest:(NSString *) JSONString {
    NSData *RPCRequest = [JSONString dataUsingEncoding:NSUTF8StringEncoding];
    if( ! RPCRequest) {
        ispy_log_debug(LOG_HTTP, "ERROR: Could not convert websocket payload into NSData");
        return nil;
    }
    
    // create a dictionary from the JSON request
    NSDictionary *RPCDictionary = [NSJSONSerialization JSONObjectWithData:RPCRequest options:kNilOptions error:nil];
    if(!RPCDictionary) {
        ispy_log_debug(LOG_HTTP, "ERROR: invalid RPC request, couldn't deserialze the JSON data.");
        return nil;
    }

    // is this a valid request? (does it contain both "messageType" and "messageData" entries?)
    if( ! [RPCDictionary objectForKey:@"messageType"] || ! [RPCDictionary objectForKey:@"messageData"]) {
        ispy_log_debug(LOG_HTTP, "ERROR: Invalid request. Must have messageType and messageData.");
        return nil;
    }

    // Verify that the iSpy RPC handler class can execute the requested selector
    NSString *selectorString = [RPCDictionary objectForKey:@"messageType"];
    SEL selectorName = sel_registerName([[NSString stringWithFormat:@"%@:", selectorString] UTF8String]);
    if(!selectorName) {
        ispy_log_debug(LOG_HTTP, "ERROR: selectorName was null.");
        return nil;
    }
    if( ! [[self rpcHandler] respondsToSelector:selectorName] ) {
        ispy_log_debug(LOG_HTTP, "ERROR: doesn't respond to selector");
        return nil;
    }

    // Do it!
    ispy_log_debug(LOG_HTTP, "Dispatching request for: %s", [selectorString UTF8String]);
    NSMutableDictionary *responseDict = [[self rpcHandler] performSelector:selectorName withObject:[RPCDictionary objectForKey:@"messageData"]];
    return responseDict;
}

@end

// This is the equivalent of [[iSpy_HTTPConnection connection] writeString:@"Wakka wakka"] except that it's
// pure C all the way down, so it's safe to call it inside the msgSend logging routines.
// NOT thread safe. Handle locking yourself.
// Requires C linkage for the msgSend stuff.
extern "C" {
    int bf_websocket_write(const char *msg) {
        if(globalMsgSendWebSocketPtr == NULL) {
            return -1;
        }
        else {
            return mg_websocket_write(globalMsgSendWebSocketPtr, 1, msg, strlen(msg));
        }
    }
}

