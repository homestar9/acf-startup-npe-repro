import java.io.ByteArrayOutputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InnerClassNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;

/**
 * Builds the one-class fix jar for the startup NullPointerException.
 *
 * Reads coldfusion/util/CaseInsensitiveMap.class from the engine's own jar (cfusion.jar, or the
 * cumulative update jar when the update ships its own copy) and changes
 * only its two default constructors, CaseInsensitiveMap() and CaseInsensitiveMap(int): where they
 * create a java.util.HashMap, they now create CaseInsensitiveMap$CFConcurrentHashMap, the
 * null-safe ConcurrentHashMap that the class already uses when constructed with concurrent=true
 * (which is how every CFML struct is built). Nothing else in the class changes.
 *
 * Usage: java -cp asm.jar;asm-tree.jar;. PatchCaseInsensitiveMap <engine jar> <out.jar>
 */
public class PatchCaseInsensitiveMap {

	static final String OWNER   = "coldfusion/util/CaseInsensitiveMap";
	static final String ENTRY   = OWNER + ".class";
	static final String HASHMAP = "java/util/HashMap";
	static final String CFCHM   = OWNER + "$CFConcurrentHashMap";

	// A fixed timestamp so the same input always gives a byte-identical jar.
	static final long FIXED_ENTRY_TIME = 946684800000L;

	public static void main( String[] args ) throws Exception {
		if ( args.length != 2 ) {
			System.err.println( "usage: PatchCaseInsensitiveMap <cfusion.jar> <out.jar>" );
			System.exit( 2 );
		}
		byte[] original;
		try ( ZipFile in = new ZipFile( args[ 0 ] ) ) {
			ZipEntry e = in.getEntry( ENTRY );
			if ( e == null ) {
				throw new IllegalStateException( ENTRY + " not found in " + args[ 0 ] );
			}
			original = readAll( in.getInputStream( e ) );
		}

		byte[] patched = patch( original );

		try ( ZipOutputStream out = new ZipOutputStream( new FileOutputStream( args[ 1 ] ) ) ) {
			ZipEntry ne = new ZipEntry( ENTRY );
			ne.setTime( FIXED_ENTRY_TIME );
			out.putNextEntry( ne );
			out.write( patched );
			out.closeEntry();
		}
		System.out.println( "Wrote " + args[ 1 ] );
	}

	static byte[] patch( byte[] original ) {
		ClassNode cn = new ClassNode();
		new ClassReader( original ).accept( cn, 0 );
		if ( !OWNER.equals( cn.name ) ) {
			throw new IllegalStateException( "expected " + OWNER + " but found " + cn.name );
		}

		boolean hasInner = false;
		if ( cn.innerClasses != null ) {
			for ( InnerClassNode ic : cn.innerClasses ) {
				if ( CFCHM.equals( ic.name ) ) hasInner = true;
			}
		}
		if ( !hasInner ) {
			throw new IllegalStateException( CFCHM + " is not declared on " + OWNER + "; refusing to patch" );
		}

		int swaps = 0;
		for ( MethodNode m : cn.methods ) {
			if ( !m.name.equals( "<init>" ) ) continue;
			if ( !m.desc.equals( "()V" ) && !m.desc.equals( "(I)V" ) ) continue;
			for ( AbstractInsnNode insn = m.instructions.getFirst(); insn != null; insn = insn.getNext() ) {
				if ( insn.getOpcode() == Opcodes.NEW && ( (TypeInsnNode) insn ).desc.equals( HASHMAP ) ) {
					( (TypeInsnNode) insn ).desc = CFCHM;
					swaps++;
				} else if ( insn.getOpcode() == Opcodes.INVOKESPECIAL ) {
					MethodInsnNode mi = (MethodInsnNode) insn;
					if ( mi.owner.equals( HASHMAP ) && mi.name.equals( "<init>" ) ) {
						// CFConcurrentHashMap has the same ()V and (I)V constructors.
						mi.owner = CFCHM;
						swaps++;
					}
				}
			}
		}
		// One NEW and one constructor call in each of the two constructors.
		if ( swaps != 4 ) {
			throw new IllegalStateException( "expected 4 HashMap references in the two default constructors, found " + swaps
				+ "; this engine's CaseInsensitiveMap is not the shape this fix was written for" );
		}

		// The stack shape is unchanged, so the existing frames stay valid and no engine classpath is needed.
		ClassWriter cw = new ClassWriter( 0 );
		cn.accept( cw );
		return cw.toByteArray();
	}

	static byte[] readAll( InputStream in ) throws Exception {
		try ( InputStream is = in ) {
			ByteArrayOutputStream bos = new ByteArrayOutputStream();
			byte[] buf = new byte[ 8192 ];
			int n;
			while ( ( n = is.read( buf ) ) > 0 ) bos.write( buf, 0, n );
			return bos.toByteArray();
		}
	}
}
