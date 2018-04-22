//
//  iTermAPIServer.m
//  iTerm2
//
//  Created by George Nachman on 11/3/16.
//
//

#import "iTermAPIServer.h"

#import "DebugLogging.h"
#import "iTermHTTPConnection.h"
#import "iTermLSOF.h"
#import "iTermWebSocketConnection.h"
#import "iTermWebSocketFrame.h"
#import "iTermSocket.h"
#import "iTermIPV4Address.h"
#import "iTermSocketIPV4Address.h"
#import "Api.pbobjc.h"
#import <objc/runtime.h>

#import <Cocoa/Cocoa.h>

NSString *const iTermWebSocketConnectionPeerIdentityBundleIdentifier = @"bundle id";
NSString *const iTermAPIServerDidReceiveMessage = @"iTermAPIServerDidReceiveMessage";
NSString *const iTermAPIServerWillSendMessage = @"iTermAPIServerWillSendMessage";
NSString *const iTermAPIServerConnectionRejected = @"iTermAPIServerConnectionRejected";
NSString *const iTermAPIServerConnectionAccepted = @"iTermAPIServerConnectionAccepted";
NSString *const iTermAPIServerConnectionClosed = @"iTermAPIServerConnectionClosed";

@interface iTermWebSocketConnection(Handle)
@property(nonatomic, readonly) id handle;
@end

@implementation iTermWebSocketConnection(Handle)

const char *kWebSocketConnectionHandleAssociatedObjectKey = "kWebSocketConnectionHandleAssociatedObjectKey";

- (id)handle {
    @synchronized (self) {
        id handle = objc_getAssociatedObject(self, kWebSocketConnectionHandleAssociatedObjectKey);
        if (!handle) {
            handle = [NSUUID UUID];
            objc_setAssociatedObject(self, kWebSocketConnectionHandleAssociatedObjectKey, handle, OBJC_ASSOCIATION_RETAIN);
        }
        return handle;
    }
}

@end

@interface iTermAPIServer()<iTermWebSocketConnectionDelegate>
@end

@interface iTermAPIRequest : NSObject
@property (nonatomic, weak) iTermWebSocketConnection *connection;
@property (nonatomic) ITMClientOriginatedMessage *request;
@end

@implementation iTermAPIRequest
@end

@interface iTermAPITransaction : NSObject
@property (nonatomic, weak) iTermWebSocketConnection *connection;

- (void)wait;
- (void)signal;

// Enqueue a request. You normally call -signal after this.
- (void)addRequest:(iTermAPIRequest *)request;

// Dequeue a request. You normally call -wait before this.
- (iTermAPIRequest *)dequeueRequestFromAnyConnection:(BOOL)anyConnection;
@end

@implementation iTermAPITransaction {
    NSMutableArray<iTermAPIRequest *> *_requests;
    NSInteger _base;
    dispatch_semaphore_t _sema;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sema = dispatch_semaphore_create(0);
        _requests = [NSMutableArray array];
    }
    return self;
}

- (void)wait {
    dispatch_semaphore_wait(_sema, DISPATCH_TIME_FOREVER);
}

- (void)signal {
    dispatch_semaphore_signal(_sema);
}

- (void)addRequest:(iTermAPIRequest *)request {
    @synchronized(self) {
        [_requests addObject:request];
    }
}

- (iTermAPIRequest *)dequeueRequestFromAnyConnection:(BOOL)anyConnection {
    @synchronized(self) {
        if (anyConnection) {
            iTermAPIRequest *request = _requests.firstObject;
            if (request) {
                [_requests removeObjectAtIndex:0];
            }
            return request;
        } else {
            while (_requests.count > _base) {
                iTermAPIRequest *request = _requests[_base];
                if (request.connection == self.connection) {
                    [_requests removeObjectAtIndex:_base];
                    return request;
                }
                _base++;
            }
            return nil;
        }
    }
}

@end

@interface iTermAPIServer()
@property (atomic) iTermAPITransaction *transaction;
@end

@implementation iTermAPIServer {
    iTermSocket *_socket;
    NSMutableDictionary<id, iTermWebSocketConnection *> *_connections;
    dispatch_queue_t _queue;
    dispatch_queue_t _executionQueue;
}

+ (instancetype)sharedInstance {
    static id instance;
    @synchronized (self) {
        if (!instance) {
            instance = [[self alloc] init];
        }
    }
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _connections = [[NSMutableDictionary alloc] init];
        _socket = [iTermSocket tcpIPV4Socket];
        if (!_socket) {
            XLog(@"Failed to create socket");
            return nil;
        }
        _queue = dispatch_queue_create("com.iterm2.apisockets", NULL);
        _executionQueue = dispatch_queue_create("com.iterm2.apiexec", DISPATCH_QUEUE_SERIAL);

        [_socket setReuseAddr:YES];
        iTermIPV4Address *loopback = [[iTermIPV4Address alloc] initWithLoopback];
        iTermSocketAddress *socketAddress = [iTermSocketAddress socketAddressWithIPV4Address:loopback
                                                                                        port:1912];
        if (![_socket bindToAddress:socketAddress]) {
            XLog(@"Failed to bind");
            return nil;
        }

        BOOL ok = [_socket listenWithBacklog:5 accept:^(int fd, iTermSocketAddress *clientAddress) {
            [self didAcceptConnectionOnFileDescriptor:fd fromAddress:clientAddress];
        }];
        if (!ok) {
            XLog(@"Failed to listen");
            return nil;
        }
    }
    return self;
}

- (void)postAPINotification:(ITMNotification *)notification toConnection:(id)connection {
    dispatch_async(_queue, ^{
        iTermWebSocketConnection *webSocketConnection = self->_connections[connection];
        if (webSocketConnection) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.notification = notification;
            dispatch_async(self->_executionQueue, ^{
                [self sendResponse:response onConnection:webSocketConnection];
            });
        }
    });
}

- (void)didAcceptConnectionOnFileDescriptor:(int)fd fromAddress:(iTermSocketAddress *)address {
    DLog(@"Accepted connection");
    __weak __typeof(self) weakSelf = self;
    dispatch_queue_t queue = _queue;
    dispatch_async(queue, ^{
        iTermHTTPConnection *connection = [[iTermHTTPConnection alloc] initWithFileDescriptor:fd clientAddress:address];

        pid_t pid = [iTermLSOF processIDWithConnectionFromAddress:address];
        if (pid == -1) {
            XLog(@"Reject connection from unidentifiable process with address %@", address);
            [connection unauthorized];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *reason = nil;
            NSString *displayName = nil;
            NSDictionary *identity = [weakSelf.delegate apiServerAuthorizeProcess:pid reason:&reason displayName:&displayName];
            if (identity) {
                dispatch_async(queue, ^{
                    [weakSelf startRequestOnConnection:connection
                                              identity:identity
                                                   pid:pid
                                           displayName:displayName
                                            authReason:reason];
                });
            } else {
                XLog(@"Reject unauthenticated process (pid %d)", pid);
                [connection unauthorized];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIServerConnectionRejected
                                                                        object:nil
                                                                      userInfo:@{ @"reason": reason ?: @"Unkown reason",
                                                                                  @"job": displayName ?: [NSNull null],
                                                                                  @"pid": @(pid) }];
                });
                return;
            }
        });
    });
}

- (void)startRequestOnConnection:(iTermHTTPConnection *)connection
                        identity:(NSDictionary *)identity
                             pid:(int)pid
                     displayName:(NSString *)displayName
                      authReason:(NSString *)authReason {
    NSURLRequest *request = [connection readRequest];
    if (!request) {
        XLog(@"Failed to read request from HTTP connection");
        [connection badRequest];
        return;
    }
    if (![request.URL.path isEqualToString:@"/"]) {
        XLog(@"Path %@ not known", request.URL.path);
        [connection badRequest];
        return;
    }
    NSString *reason = nil;
    iTermWebSocketConnection *webSocketConnection = [iTermWebSocketConnection newWebSocketConnectionForRequest:request
                                                                                                    connection:connection
                                                                                                        reason:&reason];
    if (webSocketConnection) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIServerConnectionAccepted
                                                                object:webSocketConnection.key
                                                              userInfo:@{ @"reason": authReason ?: [NSNull null],
                                                                          @"job": displayName ?: [NSNull null],
                                                                          @"pid": @(pid) }];
        });
        DLog(@"Upgrading request to websocket");
        webSocketConnection.peerIdentity = identity;
        webSocketConnection.delegate = self;
        _connections[webSocketConnection.handle] = webSocketConnection;
        [webSocketConnection handleRequest:request];
    } else {
        XLog(@"Bad request %@: %@", request, reason);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIServerConnectionRejected
                                                                object:request.allHTTPHeaderFields[@"x-iterm2-key"]
                                                              userInfo:@{ @"reason": reason ?: @"Unkown reason",
                                                                          @"job": displayName ?: [NSNull null],
                                                                          @"pid": @(pid) }];
        });
        [connection badRequest];
    }
}

- (void)sendResponse:(ITMServerOriginatedMessage *)response onConnection:(iTermWebSocketConnection *)webSocketConnection {
    DLog(@"Sending response %@", response);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIServerWillSendMessage
                                                            object:webSocketConnection.key
                                                          userInfo:@{ @"message": response }];
    });
    [webSocketConnection sendBinary:[response data]];
}

// Runs on execution queue
- (void)dispatchRequestWhileNotInTransaction:(ITMClientOriginatedMessage *)request
                                  connection:(iTermWebSocketConnection *)webSocketConnection {
    NSAssert(!self.transaction, @"Already in a transaction");

    __weak __typeof(self) weakSelf = self;
    if (request.hasTransactionRequest) {
        if (!request.transactionRequest.begin) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
                response.id_p = request.id_p;
                response.transactionResponse = [[ITMTransactionResponse alloc] init];
                response.transactionResponse.status = ITMTransactionResponse_Status_NoTransaction;
                [weakSelf sendResponse:response onConnection:webSocketConnection];
            });
            return;
        }

        iTermAPITransaction *transaction = [[iTermAPITransaction alloc] init];
        transaction.connection = webSocketConnection;
        self.transaction = transaction;

        dispatch_async(dispatch_get_main_queue(), ^{
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.transactionResponse = [[ITMTransactionResponse alloc] init];
            response.transactionResponse.status = ITMTransactionResponse_Status_Ok;
            [weakSelf sendResponse:response onConnection:webSocketConnection];

            [weakSelf drainTransaction:transaction];
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf dispatchRequest:request connection:webSocketConnection];
        });
    }
}

// Runs on main queue and blocks it during a transaction.
- (void)drainTransaction:(iTermAPITransaction *)transaction {
    while (1) {
        [transaction wait];
        if (self.transaction != transaction) {
            // Connection must have been terminated.
            break;
        }
        iTermAPIRequest *transactionRequest = [transaction dequeueRequestFromAnyConnection:NO];

        if (transactionRequest.request.hasTransactionRequest &&
            !transactionRequest.request.transactionRequest.begin) {
            // End the transaction by request.
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = transactionRequest.request.id_p;
            response.transactionResponse = [[ITMTransactionResponse alloc] init];
            response.transactionResponse.status = ITMTransactionResponse_Status_Ok;
            [self sendResponse:response onConnection:transactionRequest.connection];
            break;
        }

        [self dispatchRequest:transactionRequest.request
                   connection:transactionRequest.connection];
    }
    dispatch_async(_executionQueue, ^{
        if (self.transaction == transaction) {
            self.transaction = nil;
        }
        iTermAPIRequest *apiRequest = [transaction dequeueRequestFromAnyConnection:YES];
        while (apiRequest) {
            if (apiRequest.connection) {
                [self enqueueOrDispatchRequest:apiRequest.request onConnection:apiRequest.connection];
            }
            apiRequest = [transaction dequeueRequestFromAnyConnection:YES];
        }
    });
}

// Runs on main queue, either in or not in a transaction.
- (void)dispatchRequest:(ITMClientOriginatedMessage *)request connection:(iTermWebSocketConnection *)webSocketConnection {
    __weak __typeof(self) weakSelf = self;
    DLog(@"Got request %@", request);
    [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIServerDidReceiveMessage
                                                        object:webSocketConnection.key
                                                      userInfo:@{ @"request": request }];
    if (request.hasTransactionRequest) {
        if (request.transactionRequest.begin) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.transactionResponse = [[ITMTransactionResponse alloc] init];
            response.transactionResponse.status = ITMTransactionResponse_Status_AlreadyInTransaction;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }
        return;
    }
    if (request.hasGetBufferRequest) {
        [_delegate apiServerGetBuffer:request.getBufferRequest
                              handler:^(ITMGetBufferResponse *getBufferResponse) {
                                  ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
                                  response.id_p = request.id_p;
                                  response.getBufferResponse = getBufferResponse;
                                  [weakSelf sendResponse:response onConnection:webSocketConnection];
                              }];
        return;
    }
    if (request.hasGetPromptRequest) {
        [_delegate apiServerGetPrompt:request.getPromptRequest handler:^(ITMGetPromptResponse *getPromptResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.getPromptResponse = getPromptResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
    if (request.hasNotificationRequest) {
        [_delegate apiServerNotification:request.notificationRequest
                              connection:webSocketConnection.handle
                                 handler:^(ITMNotificationResponse *notificationResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.notificationResponse = notificationResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
    if (request.hasRegisterToolRequest) {
        [_delegate apiServerRegisterTool:request.registerToolRequest
                            peerIdentity:webSocketConnection.peerIdentity
                                 handler:^(ITMRegisterToolResponse *registerToolResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.registerToolResponse = registerToolResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
    if (request.hasSetProfilePropertyRequest) {
        [_delegate apiServerSetProfileProperty:request.setProfilePropertyRequest
                                       handler:^(ITMSetProfilePropertyResponse *setProfilePropertyResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.setProfilePropertyResponse = setProfilePropertyResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
    if (request.hasGetProfilePropertyRequest) {
        [_delegate apiServerGetProfileProperty:request.getProfilePropertyRequest
                                       handler:^(ITMGetProfilePropertyResponse *getProfilePropertyResponse) {
                                           ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
                                           response.id_p = request.id_p;
                                           response.getProfilePropertyResponse = getProfilePropertyResponse;
                                           [weakSelf sendResponse:response onConnection:webSocketConnection];
                                       }];
        return;
    }
    if (request.hasListSessionsRequest) {
        [_delegate apiServerListSessions:request.listSessionsRequest
                                 handler:^(ITMListSessionsResponse *listSessionsResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.listSessionsResponse = listSessionsResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
    if (request.hasSendTextRequest) {
        [_delegate apiServerSendText:request.sendTextRequest handler:^(ITMSendTextResponse *sendTextResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.sendTextResponse = sendTextResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
    if (request.hasCreateTabRequest) {
        [_delegate apiServerCreateTab:request.createTabRequest handler:^(ITMCreateTabResponse *createTabResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.createTabResponse = createTabResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
    if (request.hasSplitPaneRequest) {
        [_delegate apiServerSplitPane:request.splitPaneRequest handler:^(ITMSplitPaneResponse *splitPaneResponse) {
            ITMServerOriginatedMessage *response = [[ITMServerOriginatedMessage alloc] init];
            response.id_p = request.id_p;
            response.splitPaneResponse = splitPaneResponse;
            [weakSelf sendResponse:response onConnection:webSocketConnection];
        }];
        return;
    }
}

// Runs on execution queue.
- (void)addRequestToTransaction:(iTermAPIRequest *)apiRequest {
    if (apiRequest.connection == self.transaction.connection) {
        [self.transaction addRequest:apiRequest];
        [self.transaction signal];
    } else {
        [self.transaction addRequest:apiRequest];
    }
}

// Runs on execution queue
- (void)enqueueOrDispatchRequest:(ITMClientOriginatedMessage *)request onConnection:(iTermWebSocketConnection *)webSocketConnection {
    if (self.transaction) {
        iTermAPIRequest *apiRequest = [[iTermAPIRequest alloc] init];
        apiRequest.connection = webSocketConnection;
        apiRequest.request = request;
        [self addRequestToTransaction:apiRequest];
    } else {
        [self dispatchRequestWhileNotInTransaction:request connection:webSocketConnection];
    }
}

#pragma mark - iTermWebSocketConnectionDelegate

- (void)webSocketConnectionDidTerminate:(iTermWebSocketConnection *)webSocketConnection {
    dispatch_async(_queue, ^{
        DLog(@"Connection terminated");
        [self->_connections removeObjectForKey:webSocketConnection.handle];
        dispatch_async(self->_executionQueue, ^{
            if (self.transaction.connection == webSocketConnection) {
                iTermAPITransaction *transaction = self.transaction;
                self.transaction = nil;
                [transaction signal];
            }
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate apiServerDidCloseConnection:webSocketConnection.handle];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIServerConnectionClosed
                                                                    object:webSocketConnection.key];
            });
        });
    });
}

- (void)webSocketConnection:(iTermWebSocketConnection *)webSocketConnection didReadFrame:(iTermWebSocketFrame *)frame {
    if (frame.opcode == iTermWebSocketOpcodeBinary) {
        ITMClientOriginatedMessage *request = [ITMClientOriginatedMessage parseFromData:frame.payload error:nil];
        NSLog(@"Dispatch %@", request);
        if (request) {
            DLog(@"Received request: %@", request);
            __weak __typeof(self) weakSelf = self;
            dispatch_async(_executionQueue, ^{
                [weakSelf enqueueOrDispatchRequest:request onConnection:webSocketConnection];
            });
        }
    }
    DLog(@"Got a frame: %@", frame);
}

@end
