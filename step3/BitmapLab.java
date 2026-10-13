import java.util.BitSet;

public class BitmapLab {

    public static void main(String[] args) {

        BitSet setBeijingA = new BitSet();
        setBeijingA.set(1);

        BitSet setShanghaiA = new BitSet();
        setShanghaiA.set(2);
        setShanghaiA.set(3);



        BitSet setBeijingB = new BitSet();
        setBeijingB.set(1);
        setBeijingB.set(4);

        BitSet setShanghaiB = new BitSet();
        setShanghaiB.set(2);
        setShanghaiB.set(5);


        //  beijing合并
        setBeijingA.or(setBeijingB);
        System.out.println(setBeijingA.cardinality());

        // shanghai 内合并
        setShanghaiA.or(setShanghaiB);
        System.out.println(setShanghaiA.cardinality());

        // shanghai 内合并
        setShanghaiA.or(setShanghaiB);
        System.out.println(setShanghaiA.cardinality());



        test();
    }

    public static void test() {
        System.out.println("bitset =====");
        BitSet set1 = new BitSet();
        set1.set(1);
        set1.set(2);
        set1.set(3);
        System.out.println(set1.cardinality());
        System.out.println(set1.length());
        System.out.println(set1.toByteArray().length);

        BitSet set2 = new BitSet();
        set2.set(1);
        set2.set(1000000);

        System.out.println(set2.cardinality());
        System.out.println(set2.length());
        System.out.println(set2.toByteArray().length);
    }

}
