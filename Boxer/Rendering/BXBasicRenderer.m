/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXBasicRendererPrivate.h"

#pragma mark -
#pragma mark Constants

NSString * const BXRendererErrorDomain = @"BXRendererErrorDomain";

//The vertex coordinates of a viewport-covering quad in orthographic projection, unflipped and flipped
GLfloat viewportVertices[8] = {
    -1,	1,
    1,	1,
    1,	-1,
    -1,	-1
};

GLfloat viewportVerticesFlipped[8] = {
    -1,	-1,
    1,	-1,
    1,	1,
    -1,	1
};

@implementation BXBasicRenderer
@synthesize context = _context;
@synthesize currentFrame = _currentFrame;
@synthesize frameTexture = _frameTexture;
@synthesize frameRate = _frameRate;
@synthesize renderingTime = _renderingTime;
@synthesize viewport = _viewport;
@synthesize delegate = _delegate;
@synthesize tag = _tag;
@synthesize latestFrameTimestamp = _latestFrameTimestamp;

#pragma mark -
#pragma mark Helper methods

+ (CGSize) maxTextureSizeForType: (GLenum)textureType inContext: (CGLContextObj)glContext
{
    GLint maxTextureDims = 0;
    
    CGLContextObj cgl_ctx = glContext;
    switch (textureType)
    {
        case GL_TEXTURE_RECTANGLE_ARB:
            glGetIntegerv(GL_MAX_RECTANGLE_TEXTURE_SIZE_ARB, &maxTextureDims);
            break;
            
        case GL_TEXTURE_2D:
        default:
            glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureDims);
            break;
    }
    
    return CGSizeMake((CGFloat)maxTextureDims, (CGFloat)maxTextureDims);
}

+ (BOOL) context: (CGLContextObj)glContext supportsExtension: (const char *)featureName
{
    CGLContextObj cgl_ctx = glContext;
    
    return gluCheckExtension((const GLubyte *)featureName, glGetString(GL_EXTENSIONS)) == GL_TRUE;
}

#pragma mark -
#pragma mark Initialization and deallocation

- (id) initWithContext: (CGLContextObj)glContext error: (NSError **)outError
{
    self = [self init];
    if (self)
    {
        _context = glContext;
        CGLRetainContext(_context);
        
        _needsTeardown = YES;
    }
    return self;
}

- (void) prepareContext
{   
    CGLContextObj cgl_ctx = _context;
    //Check what our largest texture size we can support will be
    _maxFrameTextureSize = [self.class maxTextureSizeForType: self.frameTextureType
                                                   inContext: _context];
    
    //Disable everything we don't need
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_ALPHA_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_LIGHTING);
    glDisable(GL_CULL_FACE);
    glDisable(GL_BLEND);
    glDisable(GL_DITHER);
    glDisable(GL_FOG);
    glPixelZoom(1.0f, 1.0f);
    
    _needsTeardown = YES;
}

- (void) tearDownContext
{
    [self.frameTexture deleteTexture];
    self.frameTexture = nil;
    
    _needsTeardown = NO;
}

- (void) dealloc
{
    if (_needsTeardown)
        [self tearDownContext];
    
    if (_context)
    {
        CGLReleaseContext(_context);
        _context = NULL;
    }
}


#pragma mark -
#pragma mark Handling frame updates and canvas resizes

- (void) updateWithFrame: (BXVideoFrame *)frame
{
    BOOL needsUpdate = NO;
    if (frame != self.currentFrame)
    {   
        //If the current texture isn't large enough to fit the new frame,
        //we'll need to create a new one.
        if (![self.frameTexture canAccomodateVideoFrame: frame])
        {
            _needsNewFrameTexture = YES;
        }
        
        self.currentFrame = frame;
        needsUpdate = YES;
    }
    else
    {
        needsUpdate = frame.timestamp != self.latestFrameTimestamp;
    }
    
    if (needsUpdate)
    {
        //Even if the frame hasn't changed, it may contain new data:
        //flag that we're dirty and need re-rendering.
        _needsFrameTextureUpdate = YES;
        
        //TWEAK: update our frame texture immediately with the new frame, while we know
        //we have a complete frame in the buffer. (If we defer the update until it's time
        //to render to the screen, then we may do it while DOS is in the middle of writing
        //to the framebuffer: resulting in a 'torn' frame.)
        [self _prepareFrameTextureForFrame: frame];
    }
}

- (CGSize) maxFrameSize
{
	return _maxFrameTextureSize;
}

- (void) setViewport: (CGRect)viewport
{
    [self setViewport: viewport recalculate: YES];
}

- (void) setViewport: (CGRect)rect recalculate: (BOOL)recalculate
{
    //TODO: should we also run the viewport rect through CGRectIntegral?
    if (!CGRectEqualToRect(rect, _viewport))
    {
        _viewport = rect;
        
        if (recalculate || self.alwaysRecalculatesAfterViewportChange)
            [self recalculateViewport];
    }
}

- (void) recalculateViewport
{
    //A no-op, intended to be implemented by subclasses to perform any rendering changes
    //needed to accomodate a new viewport size.
}

- (BOOL) alwaysRecalculatesAfterViewportChange
{
    return NO;
}

#pragma mark -
#pragma mark Rendering

- (BOOL) canRender
{
	return self.frameTexture != nil;
}

- (void) render
{
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    
    BXVideoFrame *frame = self.currentFrame;
    
    [self _prepareForRenderingFrame: frame];
    [self _clearViewport];
    [self _renderFrame: frame];
    
    CFAbsoluteTime endTime = CFAbsoluteTimeGetCurrent();
    
    //After rendering, calculate how long this frame took us to render (to determine rendering speed),
    //and how long it's been since we completed the last frame (to determine overall frame rate).
    self.renderingTime = endTime - startTime;
    
    if (_previousFrameTime)
    {
        CFTimeInterval timeSinceEndOfPreviousFrame = endTime - _previousFrameTime;
        if (timeSinceEndOfPreviousFrame > 0)
            self.frameRate = (CGFloat)(1.0 / timeSinceEndOfPreviousFrame);
    }
    
    _previousFrameTime = endTime;
}

- (void) _prepareForRenderingFrame: (BXVideoFrame *)frame
{
    [self _prepareFrameTextureForFrame: frame];
}

- (void) _renderFrame: (BXVideoFrame *)frame
{
    if (self.delegate)
        [self.delegate renderer: self willRenderTextureToDestinationContext: self.frameTexture];
    
    [self _setGLViewportToRegion: self.viewport];
    [self.frameTexture drawOntoVertices: viewportVertices error: NULL];
    
    if (self.delegate)
        [self.delegate renderer: self didRenderTextureToDestinationContext: self.frameTexture];
}

- (void) _clearViewport
{
    CGLContextObj cgl_ctx = _context;
    
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}

- (void) _setGLViewportToRegion: (CGRect)viewport 
{
    CGLContextObj cgl_ctx = _context;
    
    viewport = CGRectIntegral(viewport);
	glViewport((GLint)viewport.origin.x,
			   (GLint)viewport.origin.y,
			   (GLsizei)viewport.size.width,
			   (GLsizei)viewport.size.height);
}

- (CGPoint) _scalingFactorFromFrame: (BXVideoFrame *)frame
                         toViewport: (CGRect)viewport
{
    CGSize viewportSize     = viewport.size;
	CGSize frameSize		= NSSizeToCGSize(frame.size);
	CGPoint scalingFactor	= CGPointMake(viewportSize.width / frameSize.width,
                                          viewportSize.height / frameSize.height);
    
    return scalingFactor;
}


#pragma mark -
#pragma mark Preparing resources for drawing

- (GLenum) frameTextureType
{
    return GL_TEXTURE_RECTANGLE_ARB;
}

- (void) _prepareFrameTextureForFrame: (BXVideoFrame *)frame
{
    if (!self.frameTexture || _needsNewFrameTexture)
    {
        //Clear our old frame texture straight away when replacing it,
        //so that the resources won't linger around.
        [self.frameTexture deleteTexture];
        
        NSError *textureError = nil;
        self.frameTexture = [ADBTexture2D textureWithType: self.frameTextureType
                                               videoFrame: frame
                                              inGLContext: _context
                                                    error: &textureError];
        
        NSAssert1(self.frameTexture != nil, @"Texture creation failed: %@", textureError);
        
        [self.frameTexture setMinFilter: GL_LINEAR
                              magFilter: GL_NEAREST
                               wrapping: GL_CLAMP_TO_EDGE];
        
        _needsNewFrameTexture = NO;
        _needsFrameTextureUpdate = NO;
    }
    else if (_needsFrameTextureUpdate)
    {
        [self.frameTexture fillWithVideoFrame: frame error: NULL];
        _needsFrameTextureUpdate = NO;
    }
    
    //Record the timestamp of the frame that's currently in our texture
    self.latestFrameTimestamp = frame.timestamp;
}

@end
